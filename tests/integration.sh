#!/usr/bin/env bash
# Runs only against a private daemon and disposable data root.
# shellcheck disable=SC2016 # awk programs intentionally use literal field references.
set -Eeuo pipefail

test_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_dir=${test_dir%/*}
((EUID == 0)) || { printf 'Run inside the namespaces described in README.md.\n' >&2; exit 1; }
for ns in user mnt net; do
	if [[ $(readlink "/proc/self/ns/$ns") == "$(readlink "/proc/1/ns/$ns")" ]]; then
		printf 'A private %s namespace is required. See README.md.\n' "$ns" >&2
		exit 1
	fi
done
for cmd in docker dockerd python3 tar sha256sum realpath find sort df flock awk mountpoint umount; do
	command -v "$cmd" >/dev/null || { printf 'Missing required command: %s\n' "$cmd" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/foster-integration.XXXXXXXX")
daemon_pid=
cleanup() {
	local rc=$?
	trap - EXIT
	if [[ -n $daemon_pid ]]; then
		kill -TERM "$daemon_pid" 2>/dev/null || :
		wait "$daemon_pid" 2>/dev/null || :
	fi
	if ((rc != 0)); then
		printf 'Test failed; private daemon log follows:\n' >&2
		[[ ! -f $work/dockerd.log ]] || tail -n 100 "$work/dockerd.log" >&2
	fi
	if mountpoint -q "$work/data"; then umount -l -- "$work/data"; fi
	rm -rf -- "$work"
	exit "$rc"
}
trap cleanup EXIT
mkdir -p -- "$work/data" "$work/exec" "$work/config"
printf '{}\n' >"$work/daemon.json"
socket=$work/docker.sock
export DOCKER_HOST=unix://$socket DOCKER_CONFIG=$work/config
unset DOCKER_CONTEXT

start_daemon() {
	dockerd --config-file "$work/daemon.json" --data-root "$work/data" \
		--exec-root "$work/exec" --pidfile "$work/dockerd.pid" \
		--host "$DOCKER_HOST" --group root --storage-driver overlay2 \
		--feature containerd-snapshotter=false --iptables=false --ip6tables=false \
		--bridge=none --ip-forward=false --ip-masq=false \
		>>"$work/dockerd.log" 2>&1 &
	daemon_pid=$!
	for ((i = 0; i < 60; i++)); do
		docker info >/dev/null 2>&1 && return 0
		kill -0 "$daemon_pid" 2>/dev/null || break
		sleep 1
	done
	printf 'Private Docker daemon did not become ready.\n' >&2
	return 1
}
stop_daemon() {
	kill -TERM "$daemon_pid"
	wait "$daemon_pid"
	daemon_pid=
}
require() { "$@" || { printf 'Assertion failed: %q ' "$@" >&2; printf '\n' >&2; exit 1; }; }

python3 "$test_dir/create-image-fixture.py" "$work/images.tar" >"$work/fixture.json"
mapfile -t fixture < <(python3 - "$work/fixture.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for key in ('base_image_id', 'orphan_image_id', 'base_chain_id', 'orphan_chain_id', 'base_tag', 'orphan_tag'):
    print(data[key])
PY
)
base_image=${fixture[0]} orphan_image=${fixture[1]}
base_chain=${fixture[2]#sha256:} orphan_chain=${fixture[3]#sha256:}
base_tag=${fixture[4]} orphan_tag=${fixture[5]}
layerdb=$work/data/image/overlay2/layerdb/sha256

start_daemon
docker load -i "$work/images.tar" >/dev/null
require docker image inspect "$base_tag" >/dev/null
require docker image inspect "$orphan_tag" >/dev/null
require test -d "$layerdb/$base_chain"
require test -d "$layerdb/$orphan_chain"
orphan_cache=$(<"$layerdb/$orphan_chain/cache-id")
stop_daemon

# Simulate lost image metadata while dockerd is stopped. The layer directories
# remain intact, as after an interrupted or corrupted image-store update.
python3 - "$work/data/image/overlay2" "$orphan_image" "$orphan_tag" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
image_id, tag = sys.argv[2:]
repo, name = tag.rsplit(':', 1)
refs = root / 'repositories.json'
data = json.loads(refs.read_text())
assert data['Repositories'][repo][tag] == image_id
del data['Repositories'][repo][tag]
if not data['Repositories'][repo]:
    del data['Repositories'][repo]
refs.write_text(json.dumps(data))
(root / 'imagedb/content/sha256' / image_id.removeprefix('sha256:')).unlink()
PY
start_daemon
require docker image inspect "$base_image" >/dev/null
if docker image inspect "$orphan_image" >/dev/null 2>&1; then
	printf 'Orphan image is still visible to Docker.\n' >&2; exit 1
fi
require test -d "$layerdb/$orphan_chain"
docker image ls --all --no-trunc >"$work/images-before.txt"
docker system df -v >"$work/df-before.txt"
if [[ $(<"$work/images-before.txt") == *"${orphan_image#sha256:}"* || $(<"$work/df-before.txt") == *"$orphan_chain"* ]]; then
	printf 'Docker unexpectedly listed the orphan.\n' >&2; exit 1
fi
if docker image rm "$orphan_image" >"$work/rmi.txt" 2>&1 || docker image rm "$orphan_chain" >>"$work/rmi.txt" 2>&1; then
	printf 'Docker unexpectedly removed the orphan chain by ID.\n' >&2; exit 1
fi
docker create --name foster-fixture-keeper --entrypoint /bin/true "$base_image" >/dev/null
docker image prune -a -f >"$work/prune.txt"
require test -d "$layerdb/$orphan_chain"
docker system prune -f >>"$work/prune.txt"
require test -d "$layerdb/$orphan_chain"
require docker image inspect "$base_image" >/dev/null

"$repo_dir/foster-orphan-layers.sh" --out "$work/report" --min-age-hours 0 >"$work/dry-run.log"
require test -d "$layerdb/$orphan_chain"
require awk -F '\t' -v id="$orphan_chain" '$1 == id && $2 == "orphan" {found=1} END {exit !found}' "$work/report/orphans.tsv"
require awk -F '\t' -v id="$orphan_chain" '$1 == id && $2 == "ok" {found=1} END {exit !found}' "$work/report/leaves.tsv"
"$repo_dir/foster-orphan-layers.sh" --apply --out "$work/apply" --min-age-hours 0 >"$work/apply.log"
require test ! -e "$layerdb/$orphan_chain"
require test ! -e "$work/data/overlay2/$orphan_cache"
require test -d "$layerdb/$base_chain"
require docker image inspect "$base_image" >/dev/null
require awk -F '\t' -v id="$orphan_chain" '$1 == id && $NF == "ok" {found=1} END {exit !found}' "$work/apply/apply.tsv"
printf 'PASS: Docker prune left the orphan; Foster found and removed it while retaining the shared base.\n'
