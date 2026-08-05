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

## Run it with no flags

**That is the intended way to use this, and it is what you want in almost every
case.** With no arguments the script does two things, in order:

1. **Asks.** It works out what is already on the box and asks a plain question
   about each thing it could do — phrased by what it found, so `install docker?`
   on a fresh box and `Docker 29.7.1 is installed -- update it?` on this one.
   Every question comes **first**, before any work at all.
2. **Executes.** Once you have answered, it runs to completion without stopping.
   Sudo is primed during the questions and kept warm, so even a driver install
   and a full `apt upgrade` never pause for a password.

Answer everything with Enter and you get the conservative choice: it installs
what is missing and leaves alone what is already there.

Nothing below this point is required reading. **The flags are not the
interface** — they exist so a *second* box, a cron job, or a re-run can skip the
questions by answering them up front. Reach for them when you are repeating a
decision you have already made, not when you are making it.

The one exception worth knowing: run `--check` first on a box that matters. It
asks the same questions, then prints what it *would* do instead of doing it.

### Where the settings live

Two tiers, and they answer different kinds of question:

| | holds | how you change it |
|---|---|---|
| **the questions** | *what should happen* — install docker or not, hold the driver or not, grow the root volume or not | answer them at the prompt |
| **the `CONFIGURATION` block** at the top of the script | *what values to use* — which driver branch, how much shm, where docker keeps images, how much VG space to reserve | edit those lines once for the box |

So a value like `NVIDIA_DRIVER_PKG=nvidia-driver-595-open` is not something you
are asked about on every run — it is a property of this machine, recorded in the
script with a comment saying why. Change it there and it stays changed. Each of
those lines also has a matching flag, for the runs where you want to override it
without editing anything.

Idempotent. Re-running is safe and is how you change things later — see
[Re-running is safe](#re-running-is-safe-and-is-how-you-change-things).

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

You do not need these for a normal run — the questions cover every decision.
They are for answering a question up front (so an unattended or repeat run does
not need you there), for overriding a `CONFIGURATION` value for one run, or for
narrowing the run to one step.

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

Every flag also has an environment-variable form (`NVIDIA_DRIVER_PKG`,
`DOCKER_SHM_SIZE`, `GROW_RESERVE`, …) — see the CONFIGURATION block at the top
of the script. Editing that block changes the default permanently for this box;
setting the variable on the command line changes it for one run.

## Re-running is safe, and is how you change things

There is no separate "update" mode. **Re-running the script *is* the update.**
It probes the real system every time and does only what is not already done, so
a second run after a reboot finishes what the first deferred, and a run against
an already-provisioned box is mostly a list of `--` skip lines.

Nothing is recorded in a stamp file, deliberately. A stamp file becomes a second
source of truth that goes stale the moment someone runs `apt` by hand — and then
the script starts making decisions from fiction. Because every check reads the
live system instead, a package you installed yourself, a config you edited, and
a run you interrupted half way through are all states the next run reads
correctly.

These rules hold in every step, and are what make a re-run boring:

* **`--check` changes nothing, and is honest.** Every mutation goes through a
  `run` wrapper, so a dry run prints the exact command it would have executed,
  prefixed `[would run]`. Anything that cannot go through that wrapper gets an
  explicit dry-run branch. Start here, always — and you can narrow it:

  ```bash
  ./provision-ubuntu-server.sh --check                # the whole box
  ./provision-ubuntu-server.sh --check --only nvidia  # one step
  ```

* **Files are compared before they are written.** Config files are generated in
  full and `cmp`'d against what is on disk. Identical means the file is not
  touched at all — no rewrite, no backup, no daemon restart. Different means the
  existing file is copied to `NAME.bak-YYYYmmdd-HHMMSS` *first*.

* **All questions are asked before any work starts,** and sudo is primed once up
  front and kept warm. Once you have answered, a long run never stops for input
  — you can walk away from a driver install.

* **No terminal means every default.** `... < /dev/null` never blocks and never
  prompts, which is what makes the script safe to run from cron or another
  script. Defaults are conservative: component installs default to *no*.

* **This script deletes nothing.** It has no `rm` outside its own temp
  directory: no account removal, no `lvremove`, no `mkfs`, no image pruning. The
  destructive operations it *could* do, it refuses and prints instructions for
  instead (see the data-root case below).

* **Typos are rejected, not ignored.** An unknown `--only` step or an unknown
  flag is a hard error. A mistyped step name that silently ran nothing and
  exited 0 would look exactly like success.

### What a re-run will never do on its own

This is the table to read if you are wondering whether it is safe to run right
now, on a box that is serving models.

| it will never | what a plain re-run actually does | to do it deliberately |
|---|---|---|
| move the nvidia driver | reports `installed and loaded, 4 GPU(s)` and moves on | `--only nvidia --reinstall`, or `NVIDIA_DRIVER_PKG=…` |
| unhold the nvidia packages | reports `already held (15 packages)` | same as above — the unhold is part of a deliberate change |
| migrate docker's image store | adopts the existing `data-root` and keeps it | stop docker, `rsync -aHAX`, then `--data-root` (the script prints the recipe) |
| restart docker under running containers | warns and leaves it to you | `sudo systemctl restart docker` when convenient |
| overwrite a config file | backs up first, or skips if identical | — |
| put an account in the `docker` group | only ever `--docker-user`, and only that one account | `--docker-user NAME` |
| reboot | tells you one is needed | `--reboot`, which still refuses if dkms has not built the module |

### The nvidia driver is pinned

Currently **`nvidia-driver-595-open` 595.84**, with **15 packages held**. That
pin is enforced three ways over: `apt upgrade` skips held packages,
`unattended-upgrades` skips them at 3am, and re-running this script does not
touch them either.

So the driver moves only when you say so, by one of exactly two commands:

```bash
# stay on this branch, take a newer point release when Ubuntu ships one
./provision-ubuntu-server.sh --only nvidia --reinstall

# change branch — newer, or older
NVIDIA_DRIVER_PKG=nvidia-driver-610-open ./provision-ubuntu-server.sh --only nvidia
NVIDIA_DRIVER_PKG=nvidia-driver-590-open ./provision-ubuntu-server.sh --only nvidia
```

Both unhold, install, and re-hold in one run, so the box is never left unheld.
Branches available in the configured repos: **570, 575, 580, 590, 595, 610**,
each in `-open` and proprietary form. Blackwell needs `-open`; the proprietary
modules do not support these cards.

A driver change needs a **reboot** before the new module is loaded. Until then
`nvidia-smi` reports a version mismatch and containers cannot see the GPUs, so
do it in a window where that is acceptable — not while a model is serving. The
script will not reboot unless you pass `--reboot`, and refuses even then if dkms
has not built the module for the running kernel.

What it does *not* currently support is pinning an exact point release within a
branch (`=595.84-0ubuntu0.24.04.1`). It has not mattered: apt takes the branch's
candidate, and the hold already freezes you wherever you are.

### Recipes

**The plain interactive run handles most of these** — re-run with no flags and
answer the question about the thing you want to change. The commands below are
the unattended equivalents: use them when you already know the answer, or when
you want to touch exactly one step and nothing else.

| to change | do this | what a later plain re-run does |
|---|---|---|
| driver branch | `NVIDIA_DRIVER_PKG=nvidia-driver-610-open … --only nvidia` | keeps 610, held; does not revert |
| driver point release | `--only nvidia --reinstall` | keeps it, held |
| hostname | `--hostname NAME --only hostname` | leaves it alone |
| grow `/` into free VG space | `--only lvm` and answer yes | offers again if space remains; declining is free |
| add a system package | add a line to `SYSTEM_PACKAGES`, re-run | installs only what is missing |
| upgrade docker itself | `--only docker --reinstall` | keeps it, does not upgrade |
| docker image store | `--data-root /srv/docker --only docker` | adopts whatever is configured |
| container shm / log rotation | edit `DOCKER_SHM_SIZE`, re-run `--only docker` | rewrites `daemon.json` only if it differs |
| GPU power cap | `--gpu-cap 500 --only gpustate` | keeps the unit as-is |
| docker for a new account | `--rootless-accounts NAME --only rootless` | reports already-present |
| raise memlock for an account | `--memlock-accounts "a b" --only limits` | rewrites only if the list changed |
| re-login to tailscale | `--only tailscale` and answer yes | skips, reports the tailnet IP |

`--reinstall` answers "yes, update" to *every* already-present component at once.
It is the blunt instrument: on this box it would also update docker and the
container toolkit. Prefer `--only STEP --reinstall` when you mean one thing.

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
