#!/usr/bin/env bash
# foster-orphan-layers.sh
#
# Reclaims Docker image layers that no image and no container references, on
# the classic overlay2 graphdriver image store, without touching any file under
# the Docker data root. dockerd's own reference counting does the deletion.
#
# The mechanism was verified against moby docker-v29.8.1.
#
# ---------------------------------------------------------------------------
# Mechanism
# ---------------------------------------------------------------------------
# At startup dockerd loads every layerdb/sha256/<chainID> dir into memory. A
# layer's reference count starts as its number of loaded child layers, plus one
# per container mount and one per image whose top layer it is. An orphan leaf
# (a layer nobody points at) therefore sits in memory at count 0, and dockerd
# never revisits it, so its disk space is never freed.
#
# For each orphan leaf this script builds a tiny `docker save`-format tarball:
#
#   manifest.json  [{"Config":"c.json","Layers":["absent/0",...,"absent/N"]}]
#   c.json         {"architecture":..,"os":"linux","config":{"Labels":{..}},
#                   "rootfs":{"type":"layers","diff_ids":[root..leaf]}}
#
# No layer files are included. `docker load` looks up each prefix chainID in
# the layer store first and opens a layer file only when that chainID is
# missing (load.go:127-134), so every Get succeeds and the image record takes
# one reference on the leaf. `docker rmi <full id>` then deletes the record and
# releases that reference. The release walk deletes the leaf, then each parent
# whose count drops to 0, and stops at the first ancestor something else still
# uses (layer_store.go:428-454). A shared base layer of a real image therefore
# survives. Two leaves that share an orphan ancestor reclaim in either order:
# the first walk stops at the shared ancestor and the second removes it.
#
# The image ID is sha256 of the exact c.json bytes (fs.go:120), so the script
# computes it locally and removes exactly that ID.
#
# ---------------------------------------------------------------------------
# Safety constraints (read before using --apply)
# ---------------------------------------------------------------------------
# * Lock hold time. `docker rmi` holds the image store lock and the layer store
#   lock while overlay2 deletes every dir in the chain. Pulls, loads, container
#   and pod starts, `docker images` and `docker system df` block until it ends,
#   and cancelling the client does not interrupt it. The script therefore
#   processes one chain at a time, largest first, with --max-chain-bytes to
#   skip chains that would hold the locks too long, --sleep between chains, and
#   a default of --max-chains 1 so the first run measures one chain's stall.
# * BuildKit. BuildKit's layers are recorded only in buildkit/snapshots.db and
#   take no layer-store reference until used, so after a restart they look
#   orphaned. The script refuses to run when the build cache is non-empty.
# * In-flight pulls. A pull holds its own references, so the fake image cannot
#   bring a pulled layer to 0. Layers whose layerdb dir is newer than
#   --min-age-hours are still skipped, and so is any chain that contains one.
# * Stop on failure. A load that fails part-way runs deferred releases on the
#   prefixes it already fetched, which can delete a prefix whose only child
#   failed to load at startup. A failed rmi or a
#   leaf that survives rmi means dockerd's counts disagree with the scan. In
#   every such case the script stops the whole run and prints what to check.
# * The fake image has no RepoTags (a bad or reused tag would fail the load
#   after the image exists, or move a real tag), no history and no Parent. Its
#   label holds the leaf chainID plus a nonce, so its ID cannot collide with a
#   real image; the script still aborts if that ID already exists.
# * The script never deletes, renames or writes anything under the Docker data
#   root. All removal goes through `docker load` + `docker rmi` (without -f).
# * Space comes back as the layer dirs disappear. `docker system df` never
#   counted these layers, so the script measures `df` on the data root.
#
# Requirements: bash >= 5.0, GNU find, realpath, sha256sum, tar, df, sort, flock
# (optional). jq is not required; all JSON is built with printf.

set -Eeuo pipefail
shopt -s nullglob
# C locale: ASCII [0-9a-f] ranges, '.' in EPOCHREALTIME, plain numeric sort.
export LC_ALL=C

readonly PROG=${0##*/}
readonly EXPECTED_VERSION=29.8.1
readonly LABEL_KEY=foster.orphan-layer
readonly INSPECT_BATCH=100
DOCKER=${DOCKER:-docker}

usage() {
	cat <<EOF
Usage: $PROG [options]

Reclaim orphaned overlay2 layers by loading a throwaway image that references
each orphan chain and removing it with \`docker rmi\`. Default is a read-only
dry run that writes a report. Nothing is changed without --apply.

Options:
  --apply                 Process orphan leaves (default: dry run, read-only).
  --root PATH             Docker data root (default: docker info DockerRootDir).
                          With --apply it must be the same dir dockerd reports.
  --out DIR               Empty output dir for log and TSVs
                          (default: ./foster-orphan-layers.<host>.<timestamp>).
  --min-age-hours H       Skip orphans whose layerdb dir changed in the last H
                          hours, since in-flight pulls look orphaned (default 6).
  --max-chains N          --apply: process at most N chains; 0 = no limit
                          (default 1, so a first run measures one chain).
  --max-chain-bytes B     --apply: skip chains whose orphan bytes exceed B, to
                          bound how long rmi holds dockerd's locks; 0 = no
                          limit (default 0). Suffixes K M G T (powers of 1000).
  --sleep S               --apply: seconds to wait between chains (default 5).
  -h, --help              Show this help.

Environment:
  DOCKER                  docker CLI to run (default: docker).
  TMPDIR                  Parent of the private temp dir (default: /tmp).

Stopping: create the file <out>/STOP to stop cleanly before the next chain.
Ctrl-C also stops after the chain in progress.

Exit status: 0 success, 1 preflight or usage error, 3 run stopped on a failed
load, failed rmi, or a leaf that survived rmi (see the log for what to check).
EOF
}

# ---------------------------------------------------------------------------
# Logging. Every line goes to the terminal and, once the output dir exists, to
# the timestamped log in it.
# ---------------------------------------------------------------------------
LOG=
_emit() { # fd, message
	local fd=$1 line
	shift
	printf -v line '%(%Y-%m-%dT%H:%M:%S%z)T %s' -1 "$*"
	printf '%s\n' "$line" >&"$fd"
	[[ -z $LOG ]] || printf '%s\n' "$line" >>"$LOG"
}
log() { _emit 1 "$*"; }
warn() { _emit 2 "WARN: $*"; }
die() {
	_emit 2 "ERROR: $*"
	exit 1
}
# log_block TEXT: log a multi-line command output, indented.
log_block() {
	local l
	while IFS= read -r l; do log "    | $l"; done <<<"$1"
}

# run_capture VAR CMD...: run CMD, put its stdout in VAR, log the command, its
# status and its stderr. Returns CMD's status so callers decide what a failure
# means. Large stdout is logged as a line count only.
run_capture() {
	local -n _rc_out=$1
	shift
	local rc=0 err nlines _rc_lines
	_rc_out=$("$@" 2>"$TMP/stderr") || rc=$?
	err=$(<"$TMP/stderr")
	nlines=0
	[[ -z $_rc_out ]] || { mapfile -t _rc_lines <<<"$_rc_out" && nlines=${#_rc_lines[@]}; }
	log "\$ ${*@Q} -> rc=$rc, ${nlines} stdout line(s)"
	if ((nlines > 0 && nlines <= 10)); then log_block "$_rc_out"; fi
	[[ -z $err ]] || log_block "stderr: $err"
	return "$rc"
}

# rawfile VAR PATH: read a whole small file without forking. Returns 1 when the
# file is not readable. trim VAR strips surrounding whitespace in place, the way
# dockerd's strings.TrimSpace does for diff, parent and cache-id.
rawfile() {
	local -n _rf=$1
	_rf=
	[[ -r $2 ]] || return 1
	IFS= read -r -d '' _rf <"$2" || :
}
trim() {
	local -n _tr=$1
	_tr=${_tr#"${_tr%%[![:space:]]*}"}
	_tr=${_tr%"${_tr##*[![:space:]]}"}
}

# fmt_bytes VAR N: "N B (x.xx GB)", using decimal units.
fmt_bytes() {
	local -n _fb=$1
	printf -v _fb '%d B (%d.%02d GB)' "$2" $(($2 / 1000000000)) $(($2 % 1000000000 / 10000000))
}

# df_avail VAR: free bytes on the filesystem holding the data root.
df_avail() {
	local -n _df=$1
	{ read -r _ && read -r _df; } < <(df -B1 --output=avail -- "$ROOT")
	_df=${_df//[[:space:]]/}
	[[ $_df =~ ^[0-9]+$ ]] || _df=0
}

# ---------------------------------------------------------------------------
# ChainID: chain[0] = diff[0]; chain[n] = "sha256:" + sha256hex("<chain[n-1]> <diff[n]>").
# Results are memoized because images share long base prefixes.
# ---------------------------------------------------------------------------
declare -A CHAIN_MEMO=()
CHAIN=
chain_next() { # prev diff -> CHAIN
	local key=$1\ $2 h
	if [[ -z $1 ]]; then
		CHAIN=$2
		return 0
	fi
	if [[ -z ${CHAIN_MEMO[$key]:-} ]]; then
		h=$(printf '%s' "$key" | sha256sum)
		CHAIN_MEMO[$key]=sha256:${h%% *}
	fi
	CHAIN=${CHAIN_MEMO[$key]}
}

# Output variables filled through namerefs by run_capture, fmt_bytes, df_avail
# and secs. Declared here because ShellCheck cannot follow namerefs.
info='' sysdf='' ls_out='' insp='' leftovers='' load_out=''
s_ref='' s_orph='' s_bad='' s_young='' s_reach='' s_held='' s_freed='' s_tot=''
before=0 after=0 load_s='' rmi_s='' el_s=''

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
apply=0 root_opt='' out='' min_age_hours=6 max_chains=1 max_chain_bytes=0 sleep_s=5
# Valued options and the variable each one sets.
declare -A OPTVAR=([root]=root_opt [out]=out [min-age-hours]=min_age_hours
	[max-chains]=max_chains [max-chain-bytes]=max_chain_bytes [sleep]=sleep_s)

while (($#)); do
	opt=${1#--} opt=${opt%%=*}
	case $1 in
	--apply) apply=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	--*=*)
		[[ -n ${OPTVAR[$opt]:-} ]] || die "unknown option: $1 (see --help)"
		printf -v "${OPTVAR[$opt]}" '%s' "${1#*=}"
		;;
	--*)
		[[ -n ${OPTVAR[$opt]:-} ]] || die "unknown option: $1 (see --help)"
		[[ $# -ge 2 && -n $2 ]] || die "$1 needs a value (see --help)"
		printf -v "${OPTVAR[$opt]}" '%s' "$2"
		shift
		;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

[[ $min_age_hours =~ ^[0-9]+$ ]] || die "--min-age-hours must be a whole number of hours"
[[ $max_chains =~ ^[0-9]+$ ]] || die "--max-chains must be a non-negative integer"
[[ $sleep_s =~ ^[0-9]+$ ]] || die "--sleep must be a whole number of seconds"
# Force base 10 so a leading zero is not read as octal.
min_age_hours=$((10#$min_age_hours)) max_chains=$((10#$max_chains)) sleep_s=$((10#$sleep_s))
if [[ ${max_chain_bytes^^} =~ ^([0-9]+)([KMGT]?)B?$ ]]; then
	declare -A _mult=([K]=1000 [M]=1000000 [G]=1000000000 [T]=1000000000000)
	max_chain_bytes=$((10#${BASH_REMATCH[1]} * ${_mult[${BASH_REMATCH[2]:-x}]:-1}))
else
	die "--max-chain-bytes must be bytes with an optional K/M/G/T suffix"
fi

# ---------------------------------------------------------------------------
# Preflight. Any failure aborts before the scan.
# ---------------------------------------------------------------------------
((BASH_VERSINFO[0] >= 5)) || die "bash >= 5.0 required (found $BASH_VERSION)"
((EUID == 0)) || die "must run as root: the layerdb under the Docker data root is root-only"
for tool in "$DOCKER" sha256sum tar df find sort realpath; do
	command -v -- "$tool" >/dev/null || die "required command not found: $tool"
done

# One instance per host: two runs could load a chain the other just deleted.
if command -v flock >/dev/null; then
	exec {lockfd}<"${BASH_SOURCE[0]}"
	flock -n "$lockfd" || die "another $PROG run holds the lock on ${BASH_SOURCE[0]}"
else
	warn "flock not found; not guarding against a concurrent run"
fi

# docker info: reachable daemon, overlay2 graphdriver, not the containerd store.
info_fmt=$'{{.ServerVersion}}\n{{.Driver}}\n{{.DockerRootDir}}\n{{.Architecture}}\n{{.OSType}}\n{{range .DriverStatus}}{{index . 0}}={{index . 1}}\n{{end}}'
info=$("$DOCKER" info --format "$info_fmt") || die "docker info failed: is dockerd running and reachable?"
{
	read -r srv_version || :
	read -r driver || :
	read -r info_root || :
	read -r info_arch || :
	read -r os_type || :
	mapfile -t driver_status
} <<<"$info"
[[ -n ${srv_version:-} ]] || die "docker info returned no ServerVersion: daemon not reachable"
[[ ${driver:-} == overlay2 ]] || die "storage driver is '${driver:-}', need overlay2 (classic graphdriver store)"
for kv in "${driver_status[@]}"; do
	[[ ${kv%%=*} != driver-type ]] || die "DriverStatus has '$kv': containerd image store is in use; this mechanism only applies to the classic overlay2 store"
done
[[ ${os_type:-} == linux ]] || die "OSType is '${os_type:-}', need linux"
[[ $srv_version == "$EXPECTED_VERSION" ]] ||
	warn "server version is $srv_version; the mechanism was verified against $EXPECTED_VERSION only"
# docker info reports uname -m; the image config needs the Go architecture name.
case ${info_arch:-} in
x86_64 | amd64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) die "unsupported or empty Architecture '${info_arch:-}' from docker info" ;;
esac

# Data root and layerdb.
ROOT=${root_opt:-$info_root}
[[ -n $ROOT && -d $ROOT ]] || die "data root '$ROOT' is not a directory"
ROOT=$(cd -- "$ROOT" && pwd -P)
if [[ -n $info_root && ! $ROOT -ef $info_root ]]; then
	((apply)) && die "--root $ROOT differs from dockerd's DockerRootDir $info_root; refusing --apply on a store dockerd is not using"
	warn "--root $ROOT differs from dockerd's DockerRootDir $info_root; the image list comes from dockerd"
fi
LDB=$ROOT/image/overlay2/layerdb
SHA=$LDB/sha256
IMAGEDB=$ROOT/image/overlay2/imagedb/content/sha256
[[ -d $SHA ]] || die "$SHA not found: not an overlay2 graphdriver data root"
# Resolve paths before creating any files, including through existing symlinks.
[[ -n $info_root && -d $info_root ]] || die "dockerd data root '$info_root' is not a directory"
daemon_root=$(cd -- "$info_root" && pwd -P)
printf -v TS '%(%Y%m%dT%H%M%S)T' -1
: "${out:=./foster-orphan-layers.${HOSTNAME:-host}.$TS}"
OUT=$(realpath -m -- "$out") || die "cannot resolve output dir: $out"
tmp_parent=$(realpath -e -- "${TMPDIR:-/tmp}") || die "cannot resolve TMPDIR: ${TMPDIR:-/tmp}"
[[ -d $tmp_parent ]] || die "TMPDIR is not a directory: $tmp_parent"
for protected_root in "$ROOT" "$daemon_root"; do
	[[ $OUT != "$protected_root" && $OUT != "${protected_root%/}/"* ]] || die "output dir $OUT is inside the data root; choose another --out"
	[[ $tmp_parent != "$protected_root" && $tmp_parent != "${protected_root%/}/"* ]] || die "TMPDIR $tmp_parent is inside the data root; set TMPDIR elsewhere"
done
# An empty output directory prevents pre-existing report or chain symlinks
# from redirecting writes into a protected location.
if [[ -d $OUT ]]; then
	shopt -s dotglob
	existing=("$OUT"/*)
	shopt -u dotglob
	((${#existing[@]} == 0)) || die "output dir $OUT is not empty; choose an empty directory"
fi
mkdir -p -- "$OUT/chains"
LOG=$OUT/foster-$TS.log
: >"$LOG"

TMP=''
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
	local rc=$?
	[[ -n $TMP && -d $TMP ]] && rm -rf -- "$TMP"
	((rc == 0)) || _emit 2 "exiting with status $rc (log: $LOG)"
}
trap cleanup EXIT
trap '_emit 2 "ERROR: line $LINENO: command failed: $BASH_COMMAND"' ERR
STOP_REQUESTED=0
trap 'STOP_REQUESTED=1; warn "interrupt received; stopping after the current step"' INT TERM
TMP=$(umask 077 && mktemp -d "$tmp_parent/foster-orphan-layers.XXXXXXXX")
MODES=(dry-run apply)
log "$PROG starting: mode=${MODES[apply]} out=$OUT"
log "options: root=${root_opt:-<docker info>} min-age-hours=$min_age_hours max-chains=$max_chains max-chain-bytes=$max_chain_bytes sleep=$sleep_s DOCKER=$DOCKER"
log "docker info: $DOCKER info succeeded"
log_block "$info"

# BuildKit build cache must be empty: its layers look orphaned after a restart.
run_capture sysdf "$DOCKER" system df --format '{{.Type}}|{{.TotalCount}}|{{.Size}}' ||
	die "docker system df failed; cannot verify the BuildKit build cache is empty"
bc_seen=0
while IFS='|' read -r t n s; do
	[[ $t == "Build Cache" ]] || continue
	bc_seen=1
	[[ $n == 0 && $s == 0B ]] ||
		die "BuildKit build cache is not empty (count=$n size=$s). BuildKit-only layers look orphaned after a restart and would be deleted. Run 'docker builder prune' or inspect it first."
done <<<"$sysdf"
((bc_seen)) || die "docker system df did not report a Build Cache row; cannot verify BuildKit cache is empty"
log "preflight ok: version=$srv_version driver=$driver arch=$ARCH root=$ROOT build-cache=empty"

# ---------------------------------------------------------------------------
# Scan the layerdb. Each 64-hex dir is checked the way dockerd's loadLayer
# checks it at startup (layer_store.go:119-171): diff and parent must parse as
# digests, size as an integer, cache-id must be non-empty. A dir that fails is
# not in dockerd's memory, so it is reported and never used.
# ---------------------------------------------------------------------------
declare -A DIFF=() SIZE=() PARENT=() MTIME=() BAD=() NCHILD=()
nonhex=() n_removing=0
printf -v NOW '%(%s)T' -1

while IFS=$'\t' read -r name mt; do
	if [[ ! $name =~ ^[0-9a-f]{64}$ ]]; then
		nonhex+=("$name")
		[[ $name != *-removing ]] || ((++n_removing))
		continue
	fi
	d=$SHA/$name
	MTIME[$name]=${mt%.*}
	SIZE[$name]=0
	reason=
	if rawfile v "$d/diff"; then
		trim v
		if [[ $v =~ ^sha256:[0-9a-f]{64}$ ]]; then DIFF[$name]=$v; else reason+="bad diff;"; fi
	else
		reason+="missing diff;"
	fi
	# dockerd parses size with ParseInt on the raw bytes, without trimming.
	if rawfile v "$d/size" && [[ $v =~ ^[0-9]+$ ]]; then SIZE[$name]=$v; else reason+="bad size;"; fi
	if rawfile v "$d/cache-id"; then
		trim v
		[[ -n $v ]] || reason+="empty cache-id;"
	else
		reason+="missing cache-id;"
	fi
	if [[ -e $d/parent ]]; then
		rawfile v "$d/parent" || v=
		trim v
		if [[ $v =~ ^sha256:([0-9a-f]{64})$ ]]; then
			PARENT[$name]=${BASH_REMATCH[1]}
			# Any 64-hex child counts, even a broken or young one: a parent
			# with children is never treated as a leaf (conservative).
			p=${BASH_REMATCH[1]}
			NCHILD[$p]=$((${NCHILD[$p]:-0} + 1))
		else
			reason+="bad parent;"
		fi
	fi
	[[ -z $reason ]] || BAD[$name]=${reason%;}
done < <(find "$SHA" -mindepth 1 -maxdepth 1 -type d -printf '%f\t%T@\n')

n_layers=${#MTIME[@]}
((n_layers > 0)) || die "no layerdb entries found under $SHA"
# A parent of a broken entry may itself have failed to load at startup.
for name in "${!PARENT[@]}"; do
	p=${PARENT[$name]}
	[[ -n ${MTIME[$p]:-} ]] || BAD[$name]=${BAD[$name]:+${BAD[$name]};}"parent $p missing"
done
log "layerdb: $n_layers entries, ${#BAD[@]} with bad metadata, ${#nonhex[@]} non-64-hex names skipped ($n_removing *-removing)"

# ---------------------------------------------------------------------------
# Referenced set: every chainID prefix of every image dockerd reports, every
# image config on disk (catches images dockerd failed to load), every container
# mount parent, and all their ancestors.
# ---------------------------------------------------------------------------
declare -A REF=() IMG_SEEN=()

# mark_diffs SOURCE DIFF...: mark every chain prefix of a diff_id list.
mark_diffs() {
	local src=$1 prev='' d
	shift
	for d; do
		# Later prefixes cannot be computed past a bad diff_id, so the scan
		# cannot prove what this image references.
		[[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || die "malformed diff_id '$d' from $src; cannot compute its chainIDs"

		chain_next "$prev" "$d"
		prev=$CHAIN
		REF[${CHAIN#sha256:}]=${REF[${CHAIN#sha256:}]:-$src}
	done
}

run_capture ls_out "$DOCKER" image ls -aq --no-trunc || die "docker image ls failed"
image_ids=()
if [[ -n $ls_out ]]; then
	while IFS= read -r id; do
		[[ -z $id || -n ${IMG_SEEN[$id]:-} ]] && continue
		IMG_SEEN[$id]=1
		image_ids+=("$id")
	done <<<"$ls_out"
fi
for ((i = 0; i < ${#image_ids[@]}; i += INSPECT_BATCH)); do
	run_capture insp "$DOCKER" image inspect --format '{{.Id}}|{{range .RootFS.Layers}}{{.}} {{end}}' "${image_ids[@]:i:INSPECT_BATCH}" ||
		die "docker image inspect failed (an image may have been removed mid-scan); rerun"
	while IFS='|' read -r id diffs; do
		[[ -n $id ]] || continue
		read -ra dl <<<"$diffs"
		mark_diffs image "${dl[@]}"
	done <<<"$insp"
done
log "daemon images: ${#image_ids[@]} unique IDs"

# Image configs on disk. dockerd writes compact JSON, so diff_ids can be cut
# out with parameter expansion; no jq needed.
# Only configs dockerd did not report need parsing; a pull that finished after
# `image ls` also lands here, which is harmless.
n_disk_only=0 n_disk_unparsed=0
for f in "$IMAGEDB"/*; do
	h=${f##*/}
	[[ $h =~ ^[0-9a-f]{64}$ && -z ${IMG_SEEN[sha256:$h]:-} ]] || continue
	((++n_disk_only))
	rawfile cfg "$f" || cfg=
	rest=${cfg#*\"diff_ids\":[}
	if [[ $rest == "$cfg" ]]; then
		((++n_disk_unparsed))
		warn "image config on disk not reported by dockerd and not parseable: $f"
		continue
	fi
	rest=${rest%%]*} rest=${rest//\"/}
	IFS=, read -ra dl <<<"$rest"
	mark_diffs "imagedb" "${dl[@]}"
	warn "image config on disk not reported by dockerd: sha256:$h (its layers are kept as referenced)"
done

# Leftover fake images from an interrupted run keep their chains referenced.
run_capture leftovers "$DOCKER" image ls -aq --no-trunc --filter "label=$LABEL_KEY" || die "docker image ls --filter failed"
if [[ -n $leftovers ]]; then
	while IFS= read -r id; do
		[[ -z $id ]] || warn "leftover foster image $id from an earlier run; its chain counts as referenced. Remove it with: $DOCKER rmi $id"
	done <<<"$leftovers"
fi

# Container RW layers: layerdb/mounts/<id>/parent is the image top chainID.
n_mounts=0
for f in "$LDB"/mounts/*/parent; do
	rawfile v "$f" || continue
	trim v
	[[ $v =~ ^sha256:([0-9a-f]{64})$ ]] || {
		warn "unparseable mount parent in $f"
		continue
	}
	((++n_mounts))
	REF[${BASH_REMATCH[1]}]=${REF[${BASH_REMATCH[1]}]:-mount}
done

# Close the set under parent links, so every ancestor of a referenced layer is
# referenced even where on-disk parent files and computed prefixes disagree.
for name in "${!REF[@]}"; do
	p=${PARENT[$name]:-} depth=0
	while [[ -n $p ]] && ((++depth < 1024)); do
		REF[$p]=${REF[$p]:-ancestor}
		p=${PARENT[$p]:-}
	done
done
log "referenced chainIDs: ${#REF[@]} (container mounts: $n_mounts, disk-only image configs: $n_disk_only)"

# ---------------------------------------------------------------------------
# Classify every 64-hex entry: referenced, bad, young, or orphan.
# ---------------------------------------------------------------------------
declare -A ORPHAN=() CLASS=()
min_age_s=$((min_age_hours * 3600))
ref_n=0 ref_b=0 orph_n=0 orph_b=0 bad_n=0 bad_b=0 young_n=0 young_b=0
for name in "${!MTIME[@]}"; do
	sz=${SIZE[$name]}
	if [[ -n ${REF[$name]:-} ]]; then
		CLASS[$name]=referenced
		: "$((ref_n += 1, ref_b += sz))"
	elif [[ -n ${BAD[$name]:-} ]]; then
		CLASS[$name]=bad
		: "$((bad_n += 1, bad_b += sz))"
	elif ((NOW - MTIME[$name] < min_age_s)); then
		CLASS[$name]=young
		: "$((young_n += 1, young_b += sz))"
	else
		CLASS[$name]=orphan
		ORPHAN[$name]=1
		: "$((orph_n += 1, orph_b += sz))"
	fi
done

# ---------------------------------------------------------------------------
# Leaves and their chains. A leaf is an orphan that no 64-hex entry names as
# parent. Its chain is walked root-first; every member below the first
# referenced ancestor must be a clean, old orphan, and the chainID recomputed
# from the diffs must match each dir name. Anything else skips the leaf.
# ---------------------------------------------------------------------------
declare -A L_STATUS=() L_REASON=() L_IDS=() L_DIFFS=() L_LEN=() L_ON=() L_OB=() L_EXCL=() USES=()
leaves=() ok_leaves=()
for name in "${!ORPHAN[@]}"; do
	((${NCHILD[$name]:-0} == 0)) && leaves+=("$name")
done

for leaf in "${leaves[@]}"; do
	ids=() reason='' id=$leaf depth=0
	while :; do
		if [[ -z ${MTIME[$id]:-} || -z ${DIFF[$id]:-} ]]; then
			reason="ancestor $id missing or has no valid diff"
			break
		fi
		if [[ -z ${REF[$id]:-} && -z ${ORPHAN[$id]:-} ]]; then
			reason="chain member $id is ${CLASS[$id]}${BAD[$id]:+ (${BAD[$id]})}"
			break
		fi
		ids=("$id" "${ids[@]}")
		((++depth <= 512)) || {
			reason="parent loop or chain deeper than 512"
			break
		}
		id=${PARENT[$id]:-}
		[[ -n $id ]] || break
	done
	if [[ -z $reason ]]; then
		prev='' diffs=()
		for i in "${!ids[@]}"; do
			id=${ids[i]}
			diffs+=("${DIFF[$id]}")
			chain_next "$prev" "${DIFF[$id]}"
			prev=$CHAIN
			if [[ ${CHAIN#sha256:} != "$id" ]]; then
				reason="chainID mismatch at depth $i: dir $id, computed ${CHAIN#sha256:}"
				break
			fi
		done
	fi
	if [[ -n $reason ]]; then
		L_STATUS[$leaf]=skip L_REASON[$leaf]=$reason
		warn "skipping leaf $leaf: $reason"
		continue
	fi
	on=0 ob=0 excl=0 counting_excl=1
	for ((i = ${#ids[@]} - 1; i >= 0; i--)); do
		id=${ids[i]}
		[[ -n ${ORPHAN[$id]:-} ]] || {
			counting_excl=0
			continue
		}
		: "$((on += 1, ob += SIZE[$id]))"
		USES[$id]=$((${USES[$id]:-0} + 1))
		# rmi deletes upward only while each ancestor has no other child.
		if ((counting_excl)) && ((i == ${#ids[@]} - 1 || ${NCHILD[$id]:-0} <= 1)); then
			: "$((excl += SIZE[$id]))"
		else
			counting_excl=0
		fi
	done
	L_STATUS[$leaf]=ok L_IDS[$leaf]=${ids[*]} L_DIFFS[$leaf]=${diffs[*]}
	L_LEN[$leaf]=${#ids[@]} L_ON[$leaf]=$on L_OB[$leaf]=$ob L_EXCL[$leaf]=$excl
	ok_leaves+=("$leaf")
done

# Union of orphan bytes across ok leaves (shared ancestors counted once), and
# orphans no ok leaf reaches (held by a young or broken child, for example).
reach_n=0 reach_b=0
for id in "${!USES[@]}"; do : "$((reach_n += 1, reach_b += SIZE[$id]))"; done
held_n=$((orph_n - reach_n)) held_b=$((orph_b - reach_b))

# ---------------------------------------------------------------------------
# Report (dry run and apply): stdout summary plus TSVs in the output dir.
# ---------------------------------------------------------------------------
{
	printf 'chain_id\tclass\tsize_bytes\tmtime\tparent\tdetail\n'
	for name in "${!MTIME[@]}"; do
		[[ ${CLASS[$name]} != referenced ]] || continue
		printf '%s\t%s\t%s\t%(%FT%T%z)T\t%s\t%s\n' "$name" "${CLASS[$name]}" "${SIZE[$name]}" \
			"${MTIME[$name]}" "${PARENT[$name]:-}" "${BAD[$name]:-}"
	done
	for name in "${nonhex[@]}"; do printf '%s\tskipped-name\t\t\t\tnot a 64-hex chainID\n' "$name"; done
} >"$OUT/orphans.tsv"

{
	printf 'leaf_chain_id\tstatus\tchain_len\torphan_layers\torphan_bytes\texclusive_bytes\tshared_orphan_layers\treason\n'
	for leaf in "${leaves[@]}"; do
		shared=0
		if [[ ${L_STATUS[$leaf]} == ok ]]; then
			read -ra ids <<<"${L_IDS[$leaf]}"
			for id in "${ids[@]}"; do
				if ((${USES[$id]:-0} > 1)); then ((++shared)); fi
			done
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$leaf" "${L_STATUS[$leaf]}" "${L_LEN[$leaf]:-}" \
			"${L_ON[$leaf]:-}" "${L_OB[$leaf]:-}" "${L_EXCL[$leaf]:-}" "$shared" "${L_REASON[$leaf]:-}"
	done
} | { IFS= read -r hdr && printf '%s\n' "$hdr" && sort -t$'\t' -k5,5nr; } >"$OUT/leaves.tsv"

fmt_bytes s_ref "$ref_b"
fmt_bytes s_orph "$orph_b"
fmt_bytes s_bad "$bad_b"
fmt_bytes s_young "$young_b"
fmt_bytes s_reach "$reach_b"
fmt_bytes s_held "$held_b"
log "---- report ----"
log "referenced layers:            $ref_n, $s_ref"
log "orphan layers:                $orph_n, $s_orph"
log "skipped, bad metadata:        $bad_n, $s_bad"
log "skipped, younger than ${min_age_hours}h:     $young_n, $s_young"
log "skipped, non-64-hex names:    ${#nonhex[@]} ($n_removing *-removing)"
log "orphan leaves:                ${#leaves[@]} (ok ${#ok_leaves[@]}, skipped $((${#leaves[@]} - ${#ok_leaves[@]})))"
log "reclaimable via ok leaves:    $reach_n layers, $s_reach (shared ancestors counted once)"
log "orphans not reachable:        $held_n layers, $s_held (held by a skipped leaf or a young/broken child)"
log "per-leaf detail: $OUT/leaves.tsv (orphan_bytes counts shared ancestors in every leaf that uses them;"
log "  exclusive_bytes is what that leaf's rmi alone would free now). All non-referenced entries: $OUT/orphans.tsv"

if ((apply && n_disk_unparsed)); then
	die "$n_disk_unparsed image config(s) on disk could not be parsed; refusing --apply because their layers may be counted as orphans"
fi
if ((!apply)); then
	log "dry run complete; nothing was changed. Rerun with --apply to reclaim."
	exit 0
fi

# ---------------------------------------------------------------------------
# Apply: one chain at a time, largest first.
# ---------------------------------------------------------------------------
STOPPED=0
# stop_run STAGE IMAGE_ID LEAF DETAIL: stop the whole run and say what to check.
stop_run() {
	local stage=$1 img=$2 leaf=$3 detail=$4 id state chain_ids
	_emit 2 "STOP: $stage failed for leaf $leaf (image $img): $detail"
	_emit 2 "Chain state now (root first):"
	read -ra chain_ids <<<"${L_IDS[$leaf]}"
	for id in "${chain_ids[@]}"; do
		state=present
		[[ -e $SHA/$id ]] || state=gone
		_emit 2 "    $id $state${REF[$id]:+ (referenced)}"
	done
	case $stage in
	load)
		_emit 2 "A failed load runs deferred releases on the prefixes it already fetched and can delete"
		_emit 2 "a prefix whose only child failed to load at startup. Check:"
		_emit 2 "  1. '$DOCKER image inspect $img': if it exists, the load created it; remove it with '$DOCKER rmi $img'."
		_emit 2 "  2. Which chain dirs above are gone, and whether any real image uses them ('$DOCKER image ls -a')."
		_emit 2 "  3. dockerd logs (journalctl -u docker) for 'Failed to load layer' and the load error."
		_emit 2 "  4. The layerdb metadata (diff, size, cache-id, parent) of the first missing ancestor."
		;;
	rmi)
		_emit 2 "The fake image may still exist and hold the chain. Check:"
		_emit 2 "  1. '$DOCKER image inspect $img' and '$DOCKER ps -a --filter ancestor=$img'."
		_emit 2 "  2. dockerd logs for driver.Remove errors (EBUSY/EIO/read-only). After such an error the"
		_emit 2 "     parent's count stays one too high until dockerd restarts."
		;;
	verify)
		_emit 2 "dockerd still holds another reference to the leaf: a new child layer or container, a pull"
		_emit 2 "that re-registered it, or a count left high by an earlier driver.Remove error. Rescan"
		_emit 2 "with a dry run before continuing."
		;;
	esac
	_emit 2 "Do not rerun --apply until the above is understood. Log: $LOG"
	STOPPED=1
}

mapfile -t order < <(for leaf in "${ok_leaves[@]}"; do printf '%s\t%s\n' "${L_OB[$leaf]}" "$leaf"; done | sort -t$'\t' -k1,1nr)

printf 'leaf_chain_id\timage_id\tchain_len\torphan_bytes\tlayers_removed\tload_s\trmi_s\telapsed_s\tdf_avail_before\tdf_avail_after\tdf_freed\tstatus\n' >"$OUT/apply.tsv"
done_n=0 n=0 tot_freed=0
# secs VAR START_US END_US: elapsed seconds with millisecond precision.
secs() {
	local -n _s=$1
	local d=$(($3 - $2))
	printf -v _s '%d.%03d' $((d / 1000000)) $((d % 1000000 / 1000))
}

for row in "${order[@]}"; do
	leaf=${row#*$'\t'}
	ob=${L_OB[$leaf]}
	if ((max_chains && done_n >= max_chains)); then
		log "reached --max-chains $max_chains; stopping"
		break
	fi
	if [[ -e $OUT/STOP ]] || ((STOP_REQUESTED)); then
		log "stop requested; stopping before leaf $leaf"
		break
	fi
	if ((max_chain_bytes && ob > max_chain_bytes)); then
		log "skip leaf $leaf: $ob orphan bytes > --max-chain-bytes $max_chain_bytes"
		printf '%s\t\t%s\t%s\t\t\t\t\t\t\t\tskipped-too-large\n' "$leaf" "${L_LEN[$leaf]}" "$ob" >>"$OUT/apply.tsv"
		continue
	fi
	((++n))
	read -ra ids <<<"${L_IDS[$leaf]}"
	read -ra diffs <<<"${L_DIFFS[$leaf]}"

	# Revalidate: the chain must be exactly as scanned (dockerd may have
	# deleted or re-registered layers since).
	changed=
	for i in "${!ids[@]}"; do
		rawfile v "$SHA/${ids[i]}/diff" || v=
		trim v
		[[ $v == "${diffs[i]}" ]] || changed="${ids[i]} changed or disappeared since the scan"
	done
	if [[ -n $changed ]]; then
		warn "skip leaf $leaf: $changed"
		printf '%s\t\t%s\t%s\t\t\t\t\t\t\t\tskipped-changed\n' "$leaf" "${L_LEN[$leaf]}" "$ob" >>"$OUT/apply.tsv"
		continue
	fi

	# Build the tarball. Layers point at paths that do not exist: a present
	# chainID never opens them, and a missing one fails cleanly with ENOENT.
	w=$TMP/chain-$n
	mkdir -- "$w"
	printf -v diffs_json '"%s",' "${diffs[@]}"
	layers_json=
	for i in "${!diffs[@]}"; do layers_json+="\"absent/$i\","; done
	printf -v nonce '%s%x' "${EPOCHREALTIME/./}" "${SRANDOM:-$RANDOM$RANDOM}"
	printf '[{"Config":"c.json","Layers":[%s]}]' "${layers_json%,}" >"$w/manifest.json"
	printf '{"architecture":"%s","os":"linux","config":{"Labels":{"%s":"%s-%s"}},"rootfs":{"type":"layers","diff_ids":[%s]}}' \
		"$ARCH" "$LABEL_KEY" "$leaf" "$nonce" "${diffs_json%,}" >"$w/c.json"
	h=$(sha256sum -- "$w/c.json")
	img=sha256:${h%% *}
	cp -- "$w/manifest.json" "$OUT/chains/$n-$leaf.manifest.json"
	cp -- "$w/c.json" "$OUT/chains/$n-$leaf.c.json"
	tar --numeric-owner --owner=0 --group=0 -C "$w" -cf "$w.tar" manifest.json c.json

	# The computed ID must be new, or rmi would remove an existing image.
	if "$DOCKER" image inspect --format '{{.Id}}' "$img" >/dev/null 2>&1; then
		_emit 2 "ERROR: image $img already exists; refusing to load or remove it"
		STOPPED=1
		break
	fi

	log "chain $n: leaf $leaf len=${#ids[@]} orphan_layers=${L_ON[$leaf]} orphan_bytes=$ob image=$img"
	df_avail before
	t0=${EPOCHREALTIME/./}

	if ! run_capture load_out "$DOCKER" load -q -i "$w.tar"; then
		stop_run load "$img" "$leaf" "docker load exited non-zero"
		break
	fi
	if [[ $load_out =~ Loaded\ image\ ID:\ (sha256:[0-9a-f]{64}) && ${BASH_REMATCH[1]} != "$img" ]]; then
		stop_run load "${BASH_REMATCH[1]}" "$leaf" "dockerd reported ID ${BASH_REMATCH[1]}, computed $img; not removing an unexpected ID"
		break
	fi
	if ! "$DOCKER" image inspect --format '{{.Id}}' "$img" >/dev/null 2>&1; then
		stop_run load "$img" "$leaf" "load succeeded but $img does not exist"
		break
	fi
	t1=${EPOCHREALTIME/./}

	# Full ID, no -f: a tag or container on it would make rmi refuse, which
	# is the correct outcome.
	if ! run_capture rmi_out "$DOCKER" rmi "$img"; then
		stop_run rmi "$img" "$leaf" "docker rmi exited non-zero"
		break
	fi
	t2=${EPOCHREALTIME/./}
	df_avail after

	if [[ -e $SHA/$leaf ]]; then
		stop_run verify "$img" "$leaf" "leaf layerdb dir still present after rmi"
		break
	fi
	removed=0
	for id in "${ids[@]}"; do [[ -e $SHA/$id ]] || ((++removed)); done
	leftover=("$SHA/$leaf"-*-removing)
	((${#leftover[@]} == 0)) || warn "leaf dir was renamed but not fully removed: ${leftover[*]} (freed at the next clean dockerd shutdown)"

	secs load_s "$t0" "$t1"
	secs rmi_s "$t1" "$t2"
	secs el_s "$t0" "$t2"
	freed=$((after - before))
	: "$((tot_freed += freed))"
	fmt_bytes s_freed "$freed"
	log "chain $n done: removed $removed of ${#ids[@]} chain dirs, load ${load_s}s, rmi ${rmi_s}s (lock hold), df freed $s_freed"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tok\n' "$leaf" "$img" "${#ids[@]}" "$ob" "$removed" \
		"$load_s" "$rmi_s" "$el_s" "$before" "$after" "$freed" >>"$OUT/apply.tsv"
	((++done_n))

	if ((sleep_s)) && ((!max_chains || done_n < max_chains)) && ((done_n < ${#order[@]})); then
		sleep "$sleep_s" || :
	fi
done

fmt_bytes s_tot "$tot_freed"
log "apply finished: $done_n chain(s) reclaimed, df freed $s_tot total. Results: $OUT/apply.tsv"
if ((STOPPED)); then exit 3; fi
exit 0
