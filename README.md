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
./provision-ubuntu-server.sh --dry-run   # see what it would do first
./provision-ubuntu-server.sh
```

Run it **as yourself**, not `sudo bash` — it calls `sudo` itself, once, and
keeps the credential warm so a long run never stops for a password.

## Run it with no arguments

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

Answering everything with Enter gives the conservative choice: it installs what
is missing and leaves alone what is already there.

Run `--dry-run` first on a box that matters. It asks the same questions, then
prints what it *would* do instead of doing it.

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
worker — name it at the rootless prompt in step 4 (it lists candidate accounts),
and answer yes to the rootless docker question in step 10. See
[Docker for an ordinary account](#docker-for-an-ordinary-account-rootless).

## Steps

| step | what | default |
|---|---|---|
| `hostname` | set the system hostname (+ `/etc/hosts`) | asks, defaults to current |
| `lvm` | grow the root LV into unallocated VG space | asks, **no** |
| `apt` | update + upgrade | asks if anything is upgradable, **yes** |
| `packages` | 26 system packages | always |
| `tailscale` | its own apt repo, then `tailscale up` | always; login asks |
| `mosh` | install + ensure a UTF-8 locale exists | always |
| `nvidia` | driver + nvtop, then hold against apt | asks |
| `docker` | Docker's own apt repo, system daemon, `docker` group | asks, **no** |
| `nvctk` | NVIDIA Container Toolkit + `daemon.json` | asks, implies docker |
| `rootless` | the root-only prerequisites so named accounts can run docker *without* the docker group | asks when docker is present |
| `gpustate` | systemd unit for GPU persistence mode | asks, **yes** |

The `nvidia` step also installs a **daily dkms check** (`nvidia-dkms-check.timer`),
asked with the driver and defaulting to yes. It exists for one failure with no
other symptom: an unattended kernel upgrade whose dkms rebuild *failed*. The box
keeps running perfectly on the old kernel with the old module resident — until
the next reboot boots the new kernel, finds no module, and every GPU disappears.
The check verifies the module is built for **every installed kernel**, not just
the running one, and exits non-zero when one is missing, so the unit shows in
`systemctl --failed` and in `doctor` days before that reboot.

Every step is always reached; what it *does* is decided by the question it
asked. There is no flag for running a subset — a partial provision is how you
get a box that looks finished and is not.

## The three commands

```bash
./provision-ubuntu-server.sh             # ask, then do it
./provision-ubuntu-server.sh --dry-run   # ask, then print what it would do
./provision-ubuntu-server.sh doctor      # check this box, offer fixes
./provision-ubuntu-server.sh --help      # live state + everything below, from the script
```

That is the entire interface. There are no other options, deliberately:
**anything consequential enough to want a flag is consequential enough to be
asked about.** The flags this script used to have — `--only`, `--reinstall`,
`--data-root`, `--gpu-cap` and the rest — were each a way to do something
irreversible without being asked, and are gone.

An unknown argument tells you where the decision it was trying to make actually
lives, rather than just failing.

### Where the settings live

Two tiers, answering different kinds of question:

| | holds | how you change it |
|---|---|---|
| **the questions** | *what should happen* — install docker or not, switch driver branch or not, grow the root volume or not | answer them at the prompt |
| **the `CONFIGURATION` block** at the top of the script | *what values to use* — `NVIDIA_DRIVER_PKG`, `DOCKER_DATA_ROOT`, `DOCKER_SHM_SIZE`, `GPU_POWER_CAP`, `GROW_RESERVE`, `MEMLOCK_ACCOUNTS`, `SYSTEM_PACKAGES` | edit those lines once for the box |

A value is a property of this machine, recorded in the file with a comment
saying why it is what it is — not something to re-answer on every run.
`./provision-ubuntu-server.sh --help` prints all of them with their current
settings.

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

* **`--dry-run` changes nothing, and is honest.** Every mutation goes through a
  `run` wrapper, so a dry run prints the exact command it would have executed,
  prefixed `[would run]`. Anything that cannot go through that wrapper gets an
  explicit dry-run branch. Start here, always — and you can narrow it:

  ```bash
  ./provision-ubuntu-server.sh --dry-run
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

* **Typos are rejected, not ignored.** An unknown argument is a hard error that
  explains where the decision it was trying to make actually lives.

### What a re-run will never do on its own

This is the table to read if you are wondering whether it is safe to run right
now, on a box that is serving models.

| it will never | what a plain re-run actually does | to do it deliberately |
|---|---|---|
| move the nvidia driver | reports `installed and loaded, 4 GPU(s)` and moves on | type a branch number at the driver question |
| unhold the nvidia packages | reports `already held (15 packages)` | happens only as part of a driver change you asked for |
| migrate docker's image store | adopts the existing `data-root` and keeps it | stop docker, `rsync -aHAX`, set `DOCKER_DATA_ROOT` (the script prints the recipe) |
| restart docker under running containers | warns and leaves it to you | `sudo systemctl restart docker` when convenient |
| overwrite a config file | backs up first, or skips if identical | — |
| put an account in the `docker` group | only ever `DOCKER_GROUP_USER`, and only that one account | set it in the `CONFIGURATION` block |
| reboot | tells you one is needed | `sudo reboot` — check `dkms status` first |

### The nvidia driver is pinned

Currently **`nvidia-driver-595-open` 595.84**, with **15 packages held**. That
pin is enforced three ways over: `apt upgrade` skips held packages,
`unattended-upgrades` skips them at 3am, and re-running this script does not
touch them either.

So the driver moves only when you say so, and you say so at the driver question,
which every run shows:

```
==> nvidia driver
      installed:  nvidia-driver-595-open 595.84 HELD, 15 packages
      loaded:     595.84                       4 GPU(s)
      branches:   515 520 525 530 535 550 570 575 580 590 595 610 (-open)
      available:  nothing newer on this branch
      a change needs a REBOOT before the new module loads.
keep 595, or type a branch number to switch to [595]:
```

Enter keeps what you have. Type `610` and it unholds, installs, and re-holds in
one run, so the box is never left unheld. Type `590` to go backwards — the
branch the rtx6kpro wiki validated. Blackwell needs `-open`; the proprietary
modules do not support these cards, so the `-open` variant is implied.

If a newer point release exists on your current branch, it says so and offers
it. If not, it says `nothing newer on this branch` and asks nothing.

A driver change needs a **reboot** before the new module is loaded. Until then
`nvidia-smi` reports a version mismatch and containers cannot see the GPUs, so
do it in a window where that is acceptable — not while a model is serving. The
script never reboots on its own — it tells you one is needed, and `doctor`
checks that dkms actually built the module for the running kernel before you do.

What it does *not* currently support is pinning an exact point release within a
branch (`=595.84-0ubuntu0.24.04.1`). It has not mattered: apt takes the branch's
candidate, and the hold already freezes you wherever you are.

### Recipes

Everything is either a question you answer during a normal run, or a value you
edit once. There is no third way.

| to change | how |
|---|---|
| driver branch, or a point release | type it at the driver question |
| hostname | answer the hostname prompt |
| grow `/` into free VG space | answer yes to the lvm question |
| add a system package | add a line to `SYSTEM_PACKAGES`, re-run |
| upgrade docker or the toolkit | answer yes when it says a newer version is available |
| docker image store | set `DOCKER_DATA_ROOT`, re-run |
| container shm / log rotation | set `DOCKER_SHM_SIZE`, re-run |
| GPU power cap | set `GPU_POWER_CAP`, re-run |
| docker for a new account, without root | name it at the rootless prompt |
| raise memlock for an account | set `MEMLOCK_ACCOUNTS`, re-run |
| re-login to tailscale | answer yes to the tailscale question |

A re-run after any of these is safe: the value is compared against what is on
the box, and only a real difference causes a change.

## doctor

```bash
./provision-ubuntu-server.sh doctor
```

Checks the box and offers each fix one at a time. It is read-only until you
accept something: every check runs and the whole report prints first, so you see
the picture before deciding anything. A problem it *cannot* fix from here is
still reported, with the command that would.

```
OK    nvidia 595.84 held (15 packages) -- apt cannot move it
OK    driver 595.84 loaded, 4 GPU(s) visible
OK    dkms has built the module for 6.8.0-136-generic
OK    docker 29.7.1, data-root /var/lib/docker
OK    docker log rotation configured
WARN  in the docker group, which is ROOT-EQUIVALENT: cdaniels
WARN  not inspected, home not readable as cdaniels: scratch
```

It checks the things that fail silently: the driver held or not, the module
loaded, dkms built for the *running* kernel, docker log rotation, and for each
rootless account its subuid range, linger, group membership and own
`daemon.json`. Home directories are `0750`, so when it cannot read one it says
so — finding nothing in an unreadable home is not the same as finding nothing
wrong.

Exit status is 1 if anything FAILed, so it is usable from a cron job.

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
# or set NVIDIA_DRIVER_PKG in the CONFIGURATION block to make it the default
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
# set DOCKER_DATA_ROOT in the CONFIGURATION block, then re-run
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
| `DOCKER_GROUP_USER` → `usermod -aG docker` | **root-equivalent** | a human admin |
| naming it at the rootless prompt | containers only, as that account | an agent, or any untrusted worker |

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
./provision-ubuntu-server.sh          # say yes to docker; name scratch at the rootless prompt
sudo su - scratch
./provision-ubuntu-account.sh         # say yes to the rootless docker question
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
GPU_POWER_CAP=350 ./provision-ubuntu-server.sh                   # persistent
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
`DOCKER_DATA_ROOT` a real job.

## Deliberately out of scope

- **User accounts** — `sudo adduser NAME`, then run the account script as them
- **sshd hardening** — password auth is left as Ubuntu ships it
- **Firewall rules** — see above
- **CUDA toolkit on the host** — containers bring their own
