# Handoff — gold, 2026-08-04

State of `provision-ubuntu-server`, and of `~scratch/local-models` on **gold**
(4× RTX PRO 6000 Blackwell, Ubuntu 24.04).

---

## 1. provision-ubuntu-server

**Status: written, run on gold, working.** Six commits, pushed to
`prairie-guy/provision-ubuntu-server` (`main`).

Eleven steps, each individually questioned and skippable:

```
hostname  limits  lvm  apt  packages  tailscale  mosh  nvidia  docker  nvctk  gpustate
```

All questions are asked **before any work starts**; sudo is primed once up front
and kept warm, so a long run never stops for input.

### What it did on gold

| step | result |
|---|---|
| `packages` | 25 system packages — the union of what `provision-ubuntu-account.sh` and doom's `setup.sh` need, so no per-account run ever escalates to sudo |
| `nvidia` | **held 15 packages** against apt |
| `gpustate` | `gpu-state.service` enabled — **persistence mode Enabled on all 4 GPUs** |
| `docker` | Docker 29.7.1 from Docker's own repo, `daemon.json` written |
| `nvctk` | nvidia-container-toolkit 1.19.1 |
| `lvm` | offered, declined — see below |

### Still open on gold

* **363 GB unallocated in `ubuntu-vg`.** The `lvm` step offers to grow `/` into
  it (`--reserve` controls how much to leave). Declined so far; deliberate
  decision, not an oversight.
* **`limits` step never applied.** It raises memlock for named accounts. Turned
  out not to be needed — see the memlock note in §3.

### Why the nvidia driver is held

`nvidia-driver-595-open`'s dependencies are **unversioned**, so holding the
metapackage alone still lets `libnvidia-*` move underneath it. An
`unattended-upgrades` run can then upgrade userspace while the old kernel module
stays resident — `Failed to initialize NVML: Driver/library version mismatch` —
detaching the GPUs from a running container at whatever hour that happened.

This costs nothing, because **the GPU software that churns is not on the host**.
There is no CUDA toolkit on gold at all; containers bring their own, and
`nvidia-container-toolkit` injects the host driver into them at runtime. New
models and vLLM releases are `docker pull`, not `apt`.

Driver 595.84 supports CUDA 13.2, and `ubuntu-drivers` reports 595-open as
*recommended* for these exact cards. 610 exists but is a New Feature Branch,
unvalidated on this hardware, and is **newer than the 590.48 the rtx6kpro
community wiki validated**. Move only when a container needs CUDA above 13.2.

---

## 2. Letting `scratch` use Docker without root

**This is the part most worth reading.**

`scratch` exists for an **agent** to drive. It must not have root. The naive
setup — adding it to the `docker` group — silently grants exactly that.

### The problem

Membership in the `docker` group is **root-equivalent**. The docker socket is
`root:docker`, and anyone who can reach it can run:

```bash
docker run -v /:/host -it ubuntu chroot /host
```

That is a root shell. It reads `/etc/shadow`, `~cdaniels/.ssh/id_ed25519`,
`~cdaniels/.claude/.credentials.json`, and can edit sudoers. No password, no
exploit — it is the documented behaviour of the socket.

So an agent account in the `docker` group is not a restricted worker. It is root
that happens not to have `sudo`.

This was initially configured the wrong way here: `scratch` was added to the
`docker` group by copying copper's access model. **That was a mistake** —
copper's `scratch` is uid 1000, the installer-created admin account with full
`sudo`. Gold's `scratch` is a uid 1001 worker. Same username, different role.

### The fix — rootless Docker

`scratch` gets its **own** docker daemon in its own user namespace. Containers
run as `scratch`, so bind-mounting `/` shows only what `scratch` could already
see. No escalation path.

```bash
# ── as cdaniels (admin) ──────────────────────────────────────
sudo apt install -y uidmap          # provides newuidmap/newgidmap
sudo gpasswd -d scratch docker      # REVOKE the root-equivalent group
sudo loginctl enable-linger scratch # daemon survives logout

# ── as scratch ───────────────────────────────────────────────
dockerd-rootless-setuptool.sh install

mkdir -p ~/.config/nvidia-container-runtime
cp /etc/nvidia-container-runtime/config.toml ~/.config/nvidia-container-runtime/config.toml
nvidia-ctk config \
  --config-file ~/.config/nvidia-container-runtime/config.toml \
  --set nvidia-container-cli.no-cgroups \
  --in-place

systemctl --user restart docker
```

Four things that are easy to get wrong:

1. **`no-cgroups` is mandatory.** A rootless daemon cannot manage cgroups, and
   `nvidia-container-cli` fails without this. GPU containers simply do not start.
2. **It must be the ACCOUNT's config, not `/etc`.** Setting it system-wide would
   also disable cgroup limits for rootful containers.
3. **`--config-file` goes AFTER `config`** — it is a subcommand flag, not a
   global one. `nvidia-ctk --config-file … config …` fails.
4. **`enable-linger`** — without it the daemon dies when the last session ends,
   taking the agent's containers with it.

### Verify

```bash
docker info -f '{{.SecurityOptions}}'
# → [name=seccomp,profile=builtin name=rootless name=cgroupns]

docker run --rm --device nvidia.com/gpu=all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L
# → all 4 GPUs
```

Both confirmed working on gold.

### Resulting boundary

| | scratch |
|---|---|
| `sudo` | no (may be re-added; sudo needs a password the agent lacks) |
| ssh into cdaniels | no |
| read `/home/cdaniels` | no — `drwxr-x---` |
| **docker group** | **no** |
| run GPU containers | **yes, as scratch** |

### Reproducible now

Both halves are repo config, not hand-typed:

* `provision-ubuntu-server.sh` — `uidmap` in `SYSTEM_PACKAGES`;
  `--memlock-accounts` for the `limits` step
* `provision-ubuntu-account.sh` — a `dockerrootless` step installing
  `templates/docker-daemon.json` and the account's nvidia `no-cgroups` config

```bash
./provision-ubuntu-server.sh --memlock-accounts scratch
./provision-ubuntu-account.sh --docker-rootless
```

### Rootless caveat that bit us

**A rootless daemon reads nothing from `/etc/docker`.** Everything in the system
`daemon.json` — log rotation, shm, memlock, the nvidia runtime — applies only to
the rootful daemon. `scratch` needs its own `~/.config/docker/daemon.json`, which
is what `templates/docker-daemon.json` provides. Without it: **no log rotation**
(a long-running server fills `$HOME`), 64 MB shm, and default memlock.

`scratch`'s images also live in `~/.local/share/docker`, separate from
`/var/lib/docker` — so images are not shared between accounts, and its disk usage
shows up in its own home.

---

## 3. `~scratch/local-models` on gold

**Status: running.** `qwen3.6-27b-think-fp8` serving on port 8000, TP=2 across
GPUs 0 and 1.

### What was needed

**`--gpus all` is broken on Docker 29.x.** Docker 29 routes `--gpus` through CDI
and treats it as vendor-agnostic, so it fails with `AMD CDI spec not found` even
though the NVIDIA spec is present and correct. Replaced everywhere:

```
--gpus all   →   --device nvidia.com/gpu=all
```

Verified working on **both** gold (29.7.1) and copper (29.4.0), so it is the
portable form. Applied to `_shared/template/model.sh`, the four active
`*/model.sh`, and `references/templates.md`. `_archive/` left alone.

CDI names are atomic — `nvidia.com/gpu=0,1` and `=[0,1]` both fail. One
`--device` flag per card, or `=all`.

### GPU allocation — two separate knobs

| question | mechanism |
|---|---|
| **which** cards | `--device nvidia.com/gpu=N`, repeated — a **docker** flag, before `"$IMAGE"` |
| **how many** to use | `--tensor-parallel-size N` — a **vLLM** flag, **after** `"$IMAGE"` |

Passing devices alone is not enough: vLLM defaults to TP=1 and uses only the
first visible card. Putting `--tensor-parallel-size` on the docker side gives
`unknown flag`.

The container renumbers devices, so TP always counts what was passed, never host
indices.

### Measured on gold (warm, variance <0.2%)

| | TP=1 | TP=2 |
|---|---|---|
| 1024 tokens | 121.0 tok/s | **189.4** (+57%) |
| 2048 tokens | 101.7 tok/s | **163.4** (+61%) |
| TTFT | 62–72 ms | **28–29 ms** |

**TP=2 is much faster, contrary to expectation.** Decode is
memory-bandwidth-bound: each token reads essentially all weights from HBM, so
splitting the model halves the per-GPU read and both cards do it in parallel.
The PCIe all-reduce cost is real (~1.3 MB/token, latency-dominated) but far
smaller than the bandwidth win. The 1.57× rather than 2× gap *is* that cost.

For reference, the lastloop guide quotes 120–200 tok/s for this model **with**
MTP speculative decoding. Gold is at 189 without it.

### Untried next steps

* **TP=4** — one more edit. Scaling could continue or flatten as 4-way
  all-reduce over PCIe dominates. See rtx6kpro `optimization/nccl-tuning.md`.
* **MTP speculative decoding** — `_archive/qwen3.6-27b-mtp-*` shows it has been
  run before. Stacks with TP.

### memlock — a correction

Earlier notes in this session claimed `scratch`'s memlock was ~15.6 MB and that
NCCL would fail without raising it. **That was a unit error**: `ulimit -l`
reports **KB**, so the real value is ~15.6 **GB** — generous. TP=2 works with no
`limits` step applied. The step remains available but is not a prerequisite.

### Known rough edges

* **`~/local-models` on gold came from `rsync`, not `git clone`.** rsync ignores
  `.gitignore`, so copper's runtime state came across — a stale marker in
  `_shared/state/running/` (cleared) and copper's logs in `_shared/state/logs/`
  (still there). A clone would have excluded both. Switching gold to a clone is
  recommended.
* **`local-models` has no shared remote.** Its only remote is `hermes-backup`, a
  bare repo on copper. To keep gold and copper identical, push it to GitHub and
  clone on gold; then `git pull` syncs both ways. Checked: 52 tracked files,
  2.3 MB, **no secrets** (`apiKey: "vllm-local"` is a vLLM placeholder), and **no
  absolute `/home/scratch` paths** — already portable.
* **`-p "${PORT}:${PORT}"` binds all interfaces.** The endpoint is LAN-reachable.
  Docker publishes ports *below* ufw, so no firewall rule can close it — bind
  explicitly instead: `-p 127.0.0.1:8000:8000` or the tailnet IP.
* **The torch.compile cache lives inside the container** and `--rm` discards it,
  so every start pays ~44 s of recompilation. Mounting
  `-v "$HOME/.cache/vllm:/root/.cache/vllm"` would fix it.
* **`latest-cu130` is a moving tag.** It was republished between two pulls (19 →
  23 layers). Pin a digest if gold and copper must run provably identical images.
* **The stock image may lack SM120 kernels.** The rtx6kpro wiki and the vLLM
  forum report NVFP4 producing corrupted output and FP8 silently not engaging on
  SM120 with stock images, fixed by builds with `torch_cuda_arch_list="12.0"`.
  FP8 looks healthy here (80 GB for a 27B model is consistent with FP8 weights
  plus a large KV cache), but **NVFP4 models should be checked for output
  quality** before being trusted — on copper too.

---

## 4. gold vs copper

| | copper | gold |
|---|---|---|
| `scratch` | uid 1000, **admin, sudo** | uid 1001, worker, no sudo |
| docker | rootful, `scratch` in group | **rootless** for `scratch` |
| driver | 590.48 (CUDA 13.1) | 595.84 (CUDA 13.2), **held** |
| docker log rotation | **none — unbounded** | configured |
| persistence mode | **Disabled** | Enabled |
| Docker | 29.4.0 (`--gpus all` works) | 29.7.1 (**it does not**) |
| `data-root` | `/home/scratch/models-docker` | `/var/lib/docker` |

Copper is the one missing protections — unbounded container logs and an unheld
driver on a box actively serving models. `provision-ubuntu-server.sh --check`
there is now safe to run: a bug that would have dropped copper's `data-root` and
relocated its image store was fixed in `51df894`.

**Any copper runbook that calls `sudo` will fail as `scratch@gold`.** Same
username, different privilege.
