# Docker orphan layer report

`foster-orphan-layers.service` runs one dry scan as root and exits. It does
not start Docker, run on a schedule, or pass `--apply`. The scan requires a
running local Docker daemon with the classic overlay2 image store and an empty
BuildKit cache. The script header and `--help` describe the mechanism and its
limitations; it was verified against Docker 29.8.1.

The service sends output to the journal and writes a separate report directory
under `/var/lib/foster-orphan-layers/` for each run. Reports are retained until
an administrator removes them. The directory is accessible only to root. The
script rejects report and temporary paths inside either Docker data root.

To install the files and run a report manually:

```sh
sudo install -D -m 0755 foster-orphan-layers.sh /usr/local/libexec/foster-orphan-layers.sh
sudo install -D -m 0644 foster-orphan-layers.service /etc/systemd/system/foster-orphan-layers.service
sudo systemctl daemon-reload
sudo systemctl start foster-orphan-layers.service
sudo journalctl -u foster-orphan-layers.service -b
```

The unit has no install target or timer. Review the report and the script's
safety constraints before considering an apply run. An apply run can stall
Docker operations while it removes a chain, and the apply path has not been
tested against a real Docker daemon in this repository. Run it manually with
`--apply` only after assessing the report, Docker version, and workload. The
script defaults to one chain per apply run; `--max-chain-bytes` can limit the
size of that chain. A failed load, removal, or verification requires
investigation before another apply run. A recurring timer would need to preserve
that stop condition across runs before it could safely automate reclamation.

The unit uses the local Docker socket and the script's default options. For a
different setup, use a systemd drop-in and replace `ExecStart` with an empty
assignment followed by the desired command. Keep `--apply` out of an automated
unit until its failure handling and scheduling have been designed for the host.
Systemd sends termination to the main script first and waits without a timeout,
so the script can finish its current operation and stop before the next chain.

## Integration test

Run the real-daemon test in private user, mount, and network namespaces:

```sh
unshare -Urnm bash -c 'mount -t tmpfs tmpfs /run && exec bash tests/integration.sh'
```

The test requires Linux user namespaces, permission to mount overlayfs in a user
namespace, Docker and dockerd, containerd, Python 3, and the script's normal
dependencies. It starts a disposable daemon with its own socket and data root;
it does not connect to the host daemon. The command mounts a private `/run`
because dockerd also uses paths there. All fixture files are local, so the test
does not pull an image or require network access.

The fixture loads two images that share a base. With the private daemon stopped,
the test removes the second image's record while leaving its layers on disk.
This simulates the persisted result of lost image bookkeeping; it does not
reproduce a particular crash. After restarting the daemon, the test checks
image listing, disk-usage output, removal by ID, image pruning, and system
pruning. It then checks that a dry run finds the orphan and an apply run removes
its layer and overlay directory while the shared base image remains inspectable.
The test exercises the installed Docker version, which the script may warn is
different from the version against which its mechanism was originally verified.
