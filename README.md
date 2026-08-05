# provision-ubuntu-server

Provisions the **system**, not a user account. Run it once per box, before
[provision-ubuntu-account](https://github.com/prairie-guy/provision-ubuntu-account)
is run for each user.

Its main job is installing the system packages both of those need, so **no
per-account run ever escalates to sudo** — which is what lets a non-sudo
account like `scratch` provision itself completely.

```
git clone https://github.com/prairie-guy/provision-ubuntu-server.git ~/stuff/provision-ubuntu-server
cd ~/stuff/provision-ubuntu-server
./provision-ubuntu-server.sh --check     # dry run first
./provision-ubuntu-server.sh
```

Run it **as yourself**, not `sudo bash` — it calls `sudo` itself, once, and
keeps the credential warm so a long run never stops for a password.

Idempotent. Every question is asked **before any work starts**, so once you've
answered them you can walk away.

## Where this fits

```
1.  install Ubuntu Server from the ISO     # creates the first user, with sudo
2.  log in as that user
3.  git clone <this repo>                  # git ships with the ISO
4.  ./provision-ubuntu-server.sh           # <- you are here
5.  git clone <provision-ubuntu-account>
6.  ./provision-ubuntu-account.sh          # first account
7.  sudo adduser scratch                   # each additional account
8.  sudo su - scratch
9.  git clone <provision-ubuntu-account>
10. ./provision-ubuntu-account.sh          # no sudo needed
```

For an account that needs **docker without root** — an agent, or any untrusted
worker — add `--rootless-accounts scratch` at step 4 (or re-run later with
`--only rootless`) and `--docker-rootless` at step 10. See
[Docker for an ordinary account](#docker-for-an-ordinary-account-rootless).

## Steps

| step | what | default |
|---|---|---|
| `hostname` | set the system hostname (+ `/etc/hosts`) | asks, defaults to current |
| `lvm` | grow the root LV into unallocated VG space | asks, **no** |
| `apt` | update + upgrade | asks if anything is upgradable, **yes** |
| `packages` | 25 system packages | always |
| `tailscale` | its own apt repo, then `tailscale up` | always; login asks |
| `mosh` | install + ensure a UTF-8 locale exists | always |
| `nvidia` | driver + nvtop, then hold against apt | asks |
| `docker` | Docker's own apt repo, system daemon, `docker` group | asks, **no** |
| `nvctk` | NVIDIA Container Toolkit + `daemon.json` | asks, implies docker |
| `rootless` | the root-only prerequisites so named accounts can run docker *without* the docker group | asks when docker is present |
| `gpustate` | systemd unit for GPU persistence mode | asks, **yes** |

`--only lvm,apt` runs a subset. Unknown step names are rejected rather than
silently doing nothing.

## Options

| flag | purpose |
|---|---|
| `--hostname NAME` | set the hostname; skips the prompt |
| `--check` | dry run, change nothing |
| `--only a,b` | run just these steps |
| `--reinstall` | answer yes to every already-present component |
| `--docker`, `--nvctk` | answer those questions up front |
| `--gpu-cap W` | per-GPU power cap for the systemd unit |
| `--data-root PATH` | where docker keeps images |
| `--docker-user NAME` | who gets added to the `docker` group (root-equivalent — a human admin) |
| `--rootless-accounts "a b"` | who gets the root-only half of rootless docker instead (an agent, or any untrusted worker) |
| `--reserve SIZE` | leave this much of the VG unallocated for snapshots (default 100G) |
| `--reboot` | reboot when finished, if the driver needs it |

## The nvidia driver is held on purpose

`nvidia-driver-595-open`'s dependencies are **unversioned**, so holding the
metapackage alone still lets `libnvidia-*` move underneath it. An
`unattended-upgrades` run can then upgrade the userspace libraries while the
old kernel module stays resident — `Failed to initialize NVML: Driver/library
version mismatch` — and any running inference container loses its GPUs, at
whatever hour that happened.

So the step holds every nvidia package version-tied to the driver branch —
`nvidia-prime`, `nvidia-settings` and `libnvidia-egl-wayland1` are excluded, as
they are independent Ubuntu packages whose security updates should keep flowing. Held packages are visible, not
hidden: `apt upgrade` prints "kept back" and `apt-mark showhold` lists them.

This costs nothing, because **the GPU software that actually churns is not on
the host**. There is no CUDA toolkit here at all — containers bring their own,
and `nvidia-container-toolkit` injects the host driver into them at runtime:

| layer | where |
|---|---|
| kernel module, `libcuda.so` | **host** — containers share the kernel |
| CUDA toolkit, cuDNN, NCCL | **container** |
| PyTorch, vLLM | **container** |

The only rule is *container CUDA ≤ what the host driver supports*. Driver
595.84 supports CUDA 13.2, so any 13.x image works. New models and vLLM
releases are `docker pull`, not `apt`.

Move the driver only when a container needs more than that ceiling:

```
NVIDIA_DRIVER_PKG=nvidia-driver-610-open ./provision-ubuntu-server.sh --only nvidia
sudo reboot
```

`ubuntu-drivers devices` reports 595-open as **recommended** for these cards,
and it is newer than the 590.48 the
[rtx6kpro field wiki](https://github.com/local-inference-lab/rtx6kpro)
validated. 610 exists but is a New Feature Branch, unvalidated on this hardware.

## The reboot dependency

Installing the driver **builds** the kernel module via dkms but does not
**load** it, so the GPU stays dead until reboot. Rather than track that in a
state file, each GPU step splits in two — the configure half runs regardless,
the verify/activate half defers:

| step | runs anyway | defers |
|---|---|---|
| `nvctk` | packages, `daemon.json` | `nvidia-container-cli info` |
| `gpustate` | install unit, `enable` | `systemctl start` |

A second run after the reboot finishes the deferred items, because the probes
read the real system rather than remembering anything. `--reboot` is opt-in and
**refuses** if `dkms status` shows no module built for the running kernel.

## Docker

Installed from **Docker's own apt repo**, not Ubuntu's `docker.io`. The
generated `/etc/docker/daemon.json` sets two things beyond the nvidia runtime:

```json
"log-opts": { "max-size": "100m", "max-file": "5" },
"default-shm-size": "16G",
"default-ulimits": { "memlock": { "Hard": -1, "Soft": -1 } }
```

Multi-GPU NCCL hangs or dies with cryptic OOMs when shm/memlock are left at
docker's defaults, and the default `json-file` log driver is **unbounded** — a
long-running vLLM container writing progress lines will otherwise fill `/`. Setting them daemon-side means you cannot forget the flags.

`--ipc=host` and the CUDA compat tmpfs mount stay per-container; see the
rtx6kpro wiki for those.

**`data-root` defaults to `/var/lib/docker`.** On a box where `/` is a single
volume, pointing it at `/home/...` moves bytes within the same filesystem and
gains nothing — and a root-owned image store inside a home is destroyed by
`deluser --remove-home`. The script refuses any path inside a user's home. Set
it only when there is a genuinely separate filesystem:

```
./provision-ubuntu-server.sh --only docker --data-root /srv/docker
```

Changing it after images exist is **detected and refused**, not migrated — an
interrupted copy, or one that loses hardlinks or xattrs, corrupts the overlay2
store silently. The script prints the correct `rsync -aHAX` recipe instead.

### Docker for an ordinary account (`rootless`)

Docker is **root-only out of the box**: `/var/run/docker.sock` is `root:docker`,
so a new account gets `permission denied` and nothing else. There is no "all
accounts can use docker" state. Installing docker grants nothing to anyone;
access is a separate, per-account decision with exactly two answers:

| | grants | suitable for |
|---|---|---|
| `--docker-user NAME` → `usermod -aG docker` | **root-equivalent** | a human admin |
| `--rootless-accounts "NAME"` | containers only, as that account | an agent, or any untrusted worker |

The group is root-equivalent because a member can run

```bash
docker run -v /:/host -it ubuntu chroot /host
```

which is a root shell — `/etc/shadow`, every ssh key, every stored credential,
sudoers. No password, no exploit; it is what the socket does. An account in that
group is not a restricted worker, it is root that happens not to have `sudo`.

Naming an account in **both** flags is refused, not resolved.

This step does only the parts that need root, because `provision-ubuntu-account.sh`
runs as the account and never calls sudo — that contract is what lets a non-sudo
agent account provision itself completely:

* a `/etc/subuid` + `/etc/subgid` range — `adduser` allocates one, plain
  `useradd` does not, and without it there are no uids to map into the
  account's namespace. The next free block is scanned, not hardcoded, so two
  accounts can never share a range
* `loginctl enable-linger` — without it systemd tears down the user manager
  when the account's last session ends, taking its docker daemon and every
  running container with it
* removal from the `docker` group, asked and defaulting to yes — rootless is
  pointless while it holds, and `dockerd-rootless-setuptool.sh` refuses to run
  while `/var/run/docker.sock` is writable anyway

The packages (`uidmap`, `docker-ce-rootless-extras`) already come from the
`packages` and `docker` steps.

Everything after that belongs to the account and needs no root:

```bash
sudo adduser scratch
./provision-ubuntu-server.sh --docker --rootless-accounts scratch
sudo su - scratch
./provision-ubuntu-account.sh --docker-rootless
```

which gives that account its own daemon, its own image store in
`~/.local/share/docker`, its own `~/.config/docker/daemon.json` (a rootless
daemon reads *nothing* from `/etc/docker`), and the `no-cgroups` nvidia config
that GPU containers need under rootless. Provisioning one account grants
nothing to the next.

### `--gpus all` is broken on Docker 29.x

Docker 29 routes `--gpus` through CDI and treats it as vendor-agnostic, so
`--gpus all` fails with `AMD CDI spec not found` even when the NVIDIA spec is
present and correct. Use the explicit device form:

```
docker run --rm --device nvidia.com/gpu=all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
docker run --rm --device nvidia.com/gpu=0 --device nvidia.com/gpu=1 ...   # specific cards
```

This works on every Docker version that has a CDI spec, so it is the portable
form. `nvidia-container-toolkit` generates the spec into `/var/run/cdi/` and
ships `nvidia-cdi-refresh.path` to regenerate it at boot and on driver change —
nothing for this script to do.

### Docker publishes below any firewall

`-p 8000:8000` is reachable from your whole LAN regardless of ufw, because
docker's rules are evaluated first. Bind explicitly:

```
-p 127.0.0.1:8000:8000              this host only
-p $(tailscale ip -4):8000:8000     tailnet only
```

This is why the script **never touches firewall rules** — a firewall that
doesn't govern your published ports is worse than none, because you'd trust it.

## GPU power

No cap by default: stock 600 W per card. The rtx6kpro
[power sweep](https://github.com/local-inference-lab/rtx6kpro/blob/master/hardware/blackwell-power-limit-sweep.md)
puts peak efficiency near **350 W** — about 64% of 600 W throughput at half the
power — but that is a `gpu_burn` compute benchmark, and LLM decode is
memory-bound, so the real trade is only knowable by sweeping your own workload.

```
GPU_POWER_CAP=350 ./provision-ubuntu-server.sh --only gpustate    # persistent
gpu-power 350                                                     # live, from the account repo
```

The unit exists because Ubuntu's own `nvidia-persistenced.service` ships with
`--no-persistence-mode`, so enabling it does *not* give you persistence mode.

## Adding a second NVMe

The `lvm` step only grows into **unallocated space in the existing VG**. It
never absorbs a new physical device — that is deliberate. Two options when you
add a drive:

```bash
# one pool: capacity is fungible, never guess a split
sudo vgextend ubuntu-vg /dev/nvme1n1p1
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

**Cost: `/` then spans both drives with no redundancy — either failing loses
everything, OS included.**

The alternative is a separate filesystem at e.g. `/srv/docker`, leaving `/` on
the original NVMe. Model weights and images are re-downloadable, so a failure
there costs a re-download rather than a rebuild. That is also what gives
`--data-root` a real job.

## Deliberately out of scope

- **User accounts** — `sudo adduser NAME`, then run the account script as them
- **sshd hardening** — password auth is left as Ubuntu ships it
- **Firewall rules** — see above
- **CUDA toolkit on the host** — containers bring their own
