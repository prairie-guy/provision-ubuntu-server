#!/usr/bin/env bash
#
# provision-ubuntu-server.sh -- provision the SYSTEM, not a user account.
#
# Everything here needs root and applies to the whole machine. Run it once per
# box, before provision-ubuntu-account.sh is run for each user. Its main job is
# to install the system packages both of those need, so no per-account run ever
# escalates to sudo.
#
#   ./provision-ubuntu-server.sh                  # ask about each component
#   ./provision-ubuntu-server.sh --check          # dry run, change nothing
#   ./provision-ubuntu-server.sh --only nvidia    # run just these steps
#   ./provision-ubuntu-server.sh --reinstall      # refresh what is already installed
#   ./provision-ubuntu-server.sh --docker --nvctk # answer those questions up front
#
# Idempotent: safe to re-run. Every question is asked before any work starts, so
# once you have answered them the run does not stop for input.
#
set -euo pipefail

# ============================================================================
# CONFIGURATION -- edit these, or override with the flags below.
# ============================================================================

# --- disk -------------------------------------------------------------------
# Ubuntu's installer allocates the root LV at a fraction of the volume group and
# leaves the rest unused. Grow by a percentage of the FREE extents, not 100%:
# online ext4 growth is one-way, so the remainder is snapshot headroom.
# This step is a no-op when the VG is already fully allocated.
GROW_ROOT_LV_PCT="${GROW_ROOT_LV_PCT:-90}"      # --grow-pct
GROW_MIN_BYTES=$((1024*1024*1024))              # below this, not worth resizing

# --- system packages --------------------------------------------------------
# The UNION of what provision-ubuntu-account.sh and ~/.config/doom/setup.sh
# install. Both probe with dpkg-query first, so once these exist neither ever
# calls sudo again -- which is the entire point of installing them here.
# ADDING a line is safe. REMOVING one makes some later per-account run escalate
# to sudo, which a non-sudo account cannot do.
SYSTEM_PACKAGES=(
  git curl wget bc less        # account script
  ca-certificates gnupg        # required by add_apt_repo below
  emacs-nox                    # doom's setup.sh installs this itself; without
                               # it the FIRST account run escalates to sudo
  ripgrep fd-find              # doom: completion/projectile
  aspell aspell-en             # doom: :checkers spell
  pandoc                       # doom: org/markdown export
  build-essential              # doom: compiles vterm + tree-sitter grammars
  libvterm-dev pkg-config      # doom: :term vterm needs all four of these
  cmake libtool-bin
  unzip zip                    # archives -- nothing else provides these
  rsync                        # this script's own data-root advice uses it
  pigz                         # parallel gzip; gzip uses 1 of 48 cores here
  pv                           # progress on multi-GB copies
  p7zip-full                   # 7z, which tar and unzip cannot read
)

# --- gpu --------------------------------------------------------------------
# `ubuntu-drivers devices` reports this as `recommended` for these exact cards,
# and it is NEWER than the 590.48 the rtx6kpro community wiki validated. 610 is
# available in the same repo but is a New Feature Branch, unvalidated on this
# hardware. Move only when a container needs CUDA above this driver's ceiling:
#   NVIDIA_DRIVER_PKG=nvidia-driver-610-open ./provision-ubuntu-server.sh --only nvidia
# Blackwell requires the -open kernel modules; the proprietary ones do not
# support these cards.
NVIDIA_DRIVER_PKG="${NVIDIA_DRIVER_PKG:-nvidia-driver-595-open}"
NVIDIA_EXTRA_PKGS=(nvtop)

# Per-GPU power cap in watts, applied at boot by the gpu-state unit.
# EMPTY = no cap, i.e. each card's stock 600W. This box has 2x3000W of PSU on
# 220V, so 4x600W is inside budget and capping only costs throughput.
# The rtx6kpro power sweep puts peak efficiency near 350W (~64% of 600W
# throughput at half the power) -- but that is a gpu_burn compute benchmark,
# and LLM decode is memory-bound, so the real trade is only knowable by
# sweeping your own workload. To try it: set this, then --only gpustate.
# For a LIVE, non-persistent change use `gpu-power` from the account repo.
GPU_POWER_CAP="${GPU_POWER_CAP:-}"              # --gpu-cap WATTS
GPU_STATE_UNIT="gpu-state"

# --- docker -----------------------------------------------------------------
DOCKER_PACKAGES=(
  docker-ce docker-ce-cli containerd.io
  docker-buildx-plugin docker-compose-plugin
  docker-ce-rootless-extras
)
NVCTK_PACKAGES=(nvidia-container-toolkit)

# Where docker keeps images, containers and volumes.
# EMPTY = docker's default /var/lib/docker, which is correct here: / is a single
# 3.3T ext4 volume, so relocating the tree moves bytes within the same
# filesystem and gains nothing. Set an absolute path ONLY when there is a
# genuinely different, larger filesystem -- e.g. a second NVMe at /srv/docker.
# Changing it after images exist is detected and refused, not migrated.
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-}"        # --data-root PATH

# Shared memory and locked-memory defaults for every container. Multi-GPU NCCL
# hangs or dies with cryptic OOMs when these are left at docker's defaults, and
# the rtx6kpro wiki lists --shm-size and --ulimit memlock=-1 as required for
# vLLM on these cards. Setting them daemon-side means you cannot forget them.
DOCKER_SHM_SIZE="${DOCKER_SHM_SIZE:-16G}"

# Account added to the `docker` group. Membership is root-equivalent -- you can
# bind-mount / into a container -- so this is the invoking human, not everyone.
DOCKER_GROUP_USER="${DOCKER_GROUP_USER:-${SUDO_USER:-$(id -un)}}"   # --docker-user

# ============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEMPLATES="$SCRIPT_DIR/templates"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMPD="$(mktemp -d)"

CHECK_ONLY=0
FORCE=0
DO_DOCKER=0
DO_NVCTK=0
DO_REBOOT=0
ONLY=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m--  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Single EXIT handler: a second `trap ... EXIT` would silently replace the first.
cleanup() {
  rm -rf "${TMPD:-}"
  [[ -n "${SUDO_KEEPALIVE:-}" ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null
  return 0
}
trap cleanup EXIT

run()  { if (( CHECK_ONLY )); then printf '    \033[2m[would run]\033[0m %s\n' "$*"; else "$@"; fi; }

# Ask a yes/no question. Without a terminal it takes the default silently, so an
# unattended run never blocks. `read` returns non-zero at EOF; tolerate it.
ask_yn() {
  local q="$1" def="${2:-n}" reply hint
  [[ "$def" == y ]] && hint="[Y/n]" || hint="[y/N]"
  if [[ ! -t 0 ]]; then [[ "$def" == y ]]; return; fi
  read -r -p "$q $hint " reply || true
  reply="${reply:-$def}"
  [[ "${reply,,}" == y* ]]
}

# Back up a file before replacing it.
backup() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  log "backing up $f -> $f.bak-$STAMP"
  run $SUDO cp -a "$f" "$f.bak-$STAMP"
}

hb() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"; }

# --------------------------------------------------------- apt repositories --
#
# tailscale, docker and nvidia-container-toolkit each need the same two files: a
# keyring under /usr/share/keyrings and a .list under /etc/apt/sources.list.d.
# Written three times that is three chances to get signed-by= wrong -- and a
# wrong path fails as NO_PUBKEY at the next update, long after the mistake.
#
#   add_apt_repo <name> <key-url> <repo-line> [keyring-basename]
#
# @KEYRING@ in <repo-line> is replaced with the keyring path. The keyring name
# defaults to <name>-keyring, overridable so tailscale keeps the exact filename
# its own package ships -- otherwise we would leave two keyrings behind.
#
# Idempotent BY CONTENT: the key is fetched to a temp file and compared. An
# unchanged repo rewrites nothing (so no needless update), and a rotated
# upstream key is picked up automatically.
APT_STALE=0
APT_UPDATED=0

add_apt_repo() {
  local name="$1" key_url="$2" repo_line="$3" kname="${4:-$1-keyring}"
  local keyring="/usr/share/keyrings/${kname}.gpg"
  local listfile="/etc/apt/sources.list.d/${name}.list"
  local newkey="$TMPD/$name.gpg" newlist="$TMPD/$name.list"

  command -v curl >/dev/null || die "curl is required to add the $name repo (run the packages step first)"
  command -v gpg  >/dev/null || die "gnupg is required to add the $name repo (run the packages step first)"

  # --dearmor passes an already-binary keyring through unchanged, so this
  # handles docker's ASCII-armored key and tailscale's binary one identically.
  curl -fsSL "$key_url" | gpg --batch --dearmor >"$newkey" 2>/dev/null \
    || die "could not fetch the $name signing key from $key_url"
  [[ -s "$newkey" ]] || die "the $name signing key from $key_url is empty"

  if cmp -s "$newkey" "$keyring"; then
    skip "$name apt key already current"
  else
    log "installing $name apt key -> $keyring"
    run $SUDO install -D -m 0644 -o root -g root "$newkey" "$keyring"
    APT_STALE=1
  fi

  { printf '# %s -- managed by provision-ubuntu-server.sh\n' "$name"
    printf '%s\n' "${repo_line//@KEYRING@/$keyring}"; } >"$newlist"
  if cmp -s "$newlist" "$listfile"; then
    skip "$name apt source already current"
  else
    log "installing $name apt source -> $listfile"
    run $SUDO install -D -m 0644 -o root -g root "$newlist" "$listfile"
    APT_STALE=1
  fi
}

# One apt-get update per run, and only when it can matter.
apt_update() {
  (( APT_UPDATED )) && return 0
  if (( ! APT_STALE )) \
     && [[ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -newermt '-1 hour' -print -quit 2>/dev/null)" ]]; then
    skip "apt lists are less than an hour old"
    APT_UPDATED=1; return 0
  fi
  log "apt-get update"
  run $SUDO apt-get update -qq
  APT_UPDATED=1; APT_STALE=0
}

have_pkg() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]; }

# ALWAYS returns 0. Under `set -e` a helper returning 1 to mean "nothing to do"
# would abort the script at the call site.
#
# NEEDRESTART_MODE=l: needrestart is installed on Ubuntu 24.04 server and puts up
# a full-screen "which services should be restarted?" dialog mid-install, which
# hangs an unattended run.
apt_install() {
  local missing=() p
  for p in "$@"; do have_pkg "$p" || missing+=("$p"); done
  if (( ! ${#missing[@]} )); then skip "already installed: $*"; return 0; fi
  apt_update
  log "apt install: ${missing[*]}"
  run $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
      apt-get install -y -o Dpkg::Options::=--force-confold "${missing[@]}"
  return 0
}

# ------------------------------------------------------------------- args --

while (( $# )); do
  case "$1" in
    --check)       CHECK_ONLY=1; shift ;;
    --reinstall)   FORCE=1; shift ;;
    --docker)      DO_DOCKER=1; shift ;;
    --nvctk)       DO_NVCTK=1; DO_DOCKER=1; shift ;;
    --reboot)      DO_REBOOT=1; shift ;;
    --gpu-cap)     GPU_POWER_CAP="${2:?--gpu-cap needs a wattage}"; shift 2 ;;
    --gpu-cap=*)   GPU_POWER_CAP="${1#*=}"; shift ;;
    --data-root)   DOCKER_DATA_ROOT="${2:?--data-root needs a path}"; shift 2 ;;
    --data-root=*) DOCKER_DATA_ROOT="${1#*=}"; shift ;;
    --docker-user) DOCKER_GROUP_USER="${2:?--docker-user needs a name}"; shift 2 ;;
    --grow-pct)    GROW_ROOT_LV_PCT="${2:?--grow-pct needs a number}"; shift 2 ;;
    --only)        ONLY="${2:?--only needs a comma-separated step list}"; shift 2 ;;
    --only=*)      ONLY="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# A step runs unless --only was given and does not name it. Unknown names are
# rejected: a typo would otherwise run nothing and exit 0, looking successful.
VALID_STEPS=(lvm apt packages tailscale mosh nvidia docker nvctk gpustate)
if [[ -n "$ONLY" ]]; then
  IFS=, read -r -a _requested <<<"$ONLY"
  for _s in "${_requested[@]}"; do
    [[ " ${VALID_STEPS[*]} " == *" $_s "* ]] \
      || die "unknown step '$_s'. Valid: ${VALID_STEPS[*]}"
  done
fi
want() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux"
command -v apt-get >/dev/null || die "apt-get not found; this script targets Ubuntu/Debian"
[[ -d "$TEMPLATES" ]] || die "templates/ not found next to the script"

# ------------------------------------------------------------------- root --

# Unlike the account script this one is a system tool, but it should still be
# invoked by the human rather than `sudo bash` -- so it calls sudo itself.
if [[ $EUID -eq 0 ]]; then
  SUDO=""
  [[ -n "${SUDO_USER:-}" || -n "$DOCKER_GROUP_USER" ]] \
    || die "running as root with no SUDO_USER: pass --docker-user NAME so the
   docker group addition has a target other than root"
else
  command -v sudo >/dev/null || die "sudo not found and not running as root"
  SUDO="sudo"
fi

(( CHECK_ONLY )) && warn "DRY RUN -- nothing will be changed."
log "host=$(hostname) user=${USER:-$(id -un)} kernel=$(uname -r)"

# Prime sudo BEFORE the questions: lvs/vgs need root, so the LVM question
# cannot even be composed without it. Keep the credential warm afterwards --
# sudo's cache is 15 minutes and a full run outlasts it, which would otherwise
# stop for a password long after you walked away.
if [[ -n "$SUDO" ]]; then
  if (( CHECK_ONLY )); then
    # Do not prompt during a dry run; degrade gracefully instead.
    sudo -n true 2>/dev/null || warn "--check has no cached sudo: LVM state cannot be read, that step will report unknown"
  else
    log "root is needed for the system changes below; sudo is asked for once"
    sudo -v
    while sudo -n true 2>/dev/null; do sleep 60; kill -0 "$$" 2>/dev/null || exit; done &
    SUDO_KEEPALIVE=$!
  fi
fi

# ----------------------------------------------------------------- probes --

nvidia_pkg_version() {
  local v; v="$(dpkg-query -W -f='${Version}' "$NVIDIA_DRIVER_PKG" 2>/dev/null)" || return 1
  [[ -n "$v" ]] || return 1
  v="${v#*:}"; printf '%s\n' "${v%%-*}"
}
nvidia_running_version() {
  [[ -r /proc/driver/nvidia/version ]] || return 1
  awk '/NVRM version/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}' \
      /proc/driver/nvidia/version
}
nvidia_dkms_ok() { dkms status -m nvidia 2>/dev/null | grep -q ", $(uname -r), .*: installed"; }

# The kernel module is only loaded at boot. Installing the package builds it via
# dkms but does NOT load it, and on an upgrade the OLD module stays resident
# while new userspace lands -- the classic "Driver/library version mismatch".
# So gate on the RUNNING module matching the INSTALLED package, not on presence.
gpu_ready() {
  local want have
  want="$(nvidia_pkg_version)"     || return 1
  have="$(nvidia_running_version)" || return 1
  [[ "$want" == "$have" ]]         || return 1
  nvidia-smi -L >/dev/null 2>&1
}
reboot_pending() {
  [[ -f /var/run/reboot-required ]] && return 0
  have_pkg "$NVIDIA_DRIVER_PKG" && ! gpu_ready && return 0
  return 1
}

have_docker()   { have_pkg docker-ce; }
have_nvctk()    { have_pkg nvidia-container-toolkit; }
have_tailscale(){ have_pkg tailscale; }
have_gpustate() { [[ -f "/etc/systemd/system/$GPU_STATE_UNIT.service" ]]; }
ts_logged_in()  { tailscale status >/dev/null 2>&1; }

# LVM probe. Read-only, but needs root -- hence the priming above.
LVM_OK=0; LVM_WHY="not probed"
lvm_probe() {
  local src out attr vgattr snaps
  command -v lvs >/dev/null || { LVM_WHY="lvm2 is not installed"; return 1; }
  src="$(findmnt -no SOURCE /)"  || { LVM_WHY="cannot identify the device behind /"; return 1; }
  LVM_FSTYPE="$(findmnt -no FSTYPE /)"
  $SUDO -n true 2>/dev/null || { LVM_WHY="need root to read LVM state"; return 1; }

  # lvs accepts a device path and fails cleanly on anything that is not an LV,
  # which also rejects a bare partition, mdraid, or a LUKS mapper node above it.
  out="$($SUDO lvs --noheadings --nosuffix --units b -o vg_name,lv_name,lv_size,lv_attr "$src" 2>/dev/null)" \
    || { LVM_WHY="/ is not on an LVM logical volume ($src)"; return 1; }
  read -r LVM_VG LVM_LV LVM_SIZE_B attr <<<"$out"
  LVM_SIZE_B="${LVM_SIZE_B%%.*}"
  LVM_PATH="/dev/$LVM_VG/$LVM_LV"

  case "${attr:0:1}" in
    s|S) LVM_WHY="$LVM_PATH is a snapshot, not an origin"; return 1 ;;
    V)   LVM_WHY="$LVM_PATH is a thin volume -- grow its thin pool instead"; return 1 ;;
    t)   LVM_WHY="$LVM_PATH is a thin pool"; return 1 ;;
  esac

  snaps="$($SUDO lvs --noheadings -o lv_name -S "origin=$LVM_LV" "$LVM_VG" 2>/dev/null | tr -d ' ')"
  [[ -z "$snaps" ]] || { LVM_WHY="$LVM_PATH has snapshots ($snaps); grow it by hand"; return 1; }

  vgattr="$($SUDO vgs --noheadings -o vg_attr "$LVM_VG" 2>/dev/null | tr -d ' ')"
  [[ "${vgattr:3:1}" == "p" ]] && { LVM_WHY="volume group $LVM_VG is PARTIAL (a PV is missing)"; return 1; }

  LVM_FREE_B="$($SUDO vgs --noheadings --nosuffix --units b -o vg_free "$LVM_VG" 2>/dev/null | tr -d ' ')"
  LVM_FREE_B="${LVM_FREE_B%%.*}"
  (( LVM_FREE_B >= GROW_MIN_BYTES )) \
    || { LVM_WHY="volume group $LVM_VG is already fully allocated"; return 1; }

  case "$LVM_FSTYPE" in
    ext2|ext3|ext4|xfs) : ;;
    *) LVM_WHY="/ is $LVM_FSTYPE; this script only grows ext4 and xfs"; return 1 ;;
  esac

  LVM_ADD_B=$(( LVM_FREE_B * GROW_ROOT_LV_PCT / 100 ))
  LVM_OK=1
}

# --------------------------------------------------------------- questions --
#
# One question per component, phrased by what is actually there: "install X?"
# when absent, "update X?" when present. Asked here, before any work, so a long
# run never stops for input. A flag already given is taken as the answer.
# --reinstall answers yes to every component that is present.

DO_GROW_LV=0
FORCE_DOCKER=$FORCE; FORCE_NVCTK=$FORCE; FORCE_GPUSTATE=$FORCE
FORCE_TAILSCALE=$FORCE; FORCE_NVIDIA=$FORCE
DO_TS_UP=0; DO_HOLD_NVIDIA=0; DO_UPGRADE=0

if want lvm; then
  if lvm_probe; then
    printf '\n'
    log "/ is $LVM_PATH ($LVM_FSTYPE) in volume group $LVM_VG"
    printf '      logical volume: %s\n' "$(hb "$LVM_SIZE_B")"
    printf '      unallocated:    %s\n' "$(hb "$LVM_FREE_B")"
    printf '      would grow by:  ~%s (%s%% of free)\n' "$(hb "$LVM_ADD_B")" "$GROW_ROOT_LV_PCT"
    printf '      then:           resize the filesystem online, / stays mounted\n'
    ask_yn "grow the root volume now?" n && DO_GROW_LV=1
  fi
fi

if want apt; then
  _upgradable="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
  if (( _upgradable > 0 )); then
    ask_yn "$_upgradable package(s) can be upgraded -- run apt upgrade now?" y && DO_UPGRADE=1
  fi
fi

if want tailscale; then
  if have_tailscale && ! ts_logged_in; then
    ask_yn "tailscale is installed but not logged in -- run 'tailscale up' (interactive browser auth)?" y && DO_TS_UP=1
  elif ! have_tailscale; then
    ask_yn "install tailscale and log in (interactive browser auth)?" y && DO_TS_UP=1
  fi
fi

if want nvidia; then
  if have_pkg "$NVIDIA_DRIVER_PKG"; then
    if (( ! FORCE_NVIDIA )) && ask_yn "$NVIDIA_DRIVER_PKG $(nvidia_pkg_version) is installed -- reinstall/update it?" n; then
      FORCE_NVIDIA=1
    fi
  fi
  # Holding matters because the metapackage's deps are UNVERSIONED, so an
  # unattended security update can move libnvidia-* underneath the loaded
  # module and detach the GPUs from a running inference server.
  if ! apt-mark showhold 2>/dev/null | grep -q '^nvidia-'; then
    ask_yn "hold the nvidia packages so apt/unattended-upgrades cannot move them?" y && DO_HOLD_NVIDIA=1
  fi
fi

if want docker; then
  if have_docker; then
    if (( ! FORCE_DOCKER )) && ask_yn "Docker $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) is installed -- update it?" n; then
      FORCE_DOCKER=1; DO_DOCKER=1
    fi
    DO_DOCKER=1
  elif (( ! DO_DOCKER )); then
    ask_yn "install Docker Engine from Docker's own apt repo (system daemon; adds $DOCKER_GROUP_USER to the docker group, which is root-equivalent)?" n && DO_DOCKER=1
  fi
fi

if want nvctk; then
  if have_nvctk; then
    if (( ! FORCE_NVCTK )) && ask_yn "the NVIDIA Container Toolkit is installed -- update it?" n; then
      FORCE_NVCTK=1; DO_NVCTK=1
    fi
    DO_NVCTK=1
  elif (( ! DO_NVCTK )) && (( DO_DOCKER )); then
    ask_yn "install the NVIDIA Container Toolkit so containers can use the GPUs?" y && { DO_NVCTK=1; DO_DOCKER=1; }
  fi
fi

if want gpustate; then
  if have_gpustate; then
    (( ! FORCE_GPUSTATE )) && ask_yn "the $GPU_STATE_UNIT unit is installed -- replace it?" n && FORCE_GPUSTATE=1
  else
    ask_yn "install a systemd unit enabling GPU persistence mode at boot (power cap: ${GPU_POWER_CAP:-none, stock 600W})?" y || SKIP_GPUSTATE=1
  fi
fi

# Only offered when the nvidia step will actually install something.
if want nvidia && ! have_pkg "$NVIDIA_DRIVER_PKG" && (( ! DO_REBOOT )); then
  ask_yn "a reboot will be needed before the GPUs work -- reboot automatically when this finishes?" n && DO_REBOOT=1
fi

DEFERRED=()
defer() { DEFERRED+=("$1"); warn "deferred until after the reboot: $1"; }

CODENAME="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
ARCH="$(dpkg --print-architecture)"

# ------------------------------------------------------------------- 1. lvm --

if want lvm; then
  if (( ! LVM_OK )); then
    skip "$LVM_WHY"
  elif (( ! DO_GROW_LV )); then
    skip "leaving $LVM_PATH at its current size"
  else
    # Let LVM do the arithmetic with the same %FREE expression that was shown.
    log "growing $LVM_PATH by ${GROW_ROOT_LV_PCT}% of free extents"
    run $SUDO lvextend -l "+${GROW_ROOT_LV_PCT}%FREE" "$LVM_PATH"
    # resize2fs takes the DEVICE; xfs_growfs takes the MOUNT POINT. Swapping
    # them is the most common way this goes wrong, so both are written out.
    case "$LVM_FSTYPE" in
      ext2|ext3|ext4) run $SUDO resize2fs "$LVM_PATH" ;;
      xfs)            run $SUDO xfs_growfs / ;;
    esac
    (( CHECK_ONLY )) || log "/ is now $(df -h --output=size / | tail -1 | tr -d ' ')"
  fi
fi

# ------------------------------------------------------------------- 2. apt --

if want apt; then
  apt_update
  if (( DO_UPGRADE )); then
    # --with-new-pkgs is what Ubuntu's plain `apt upgrade` does, and it is what
    # lets a new linux-generic come in. autoremove is deliberately NEVER run:
    # it can remove a kernel or the driver metapackage on a box reached only
    # over the network.
    log "apt upgrade"
    run $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        apt-get upgrade --with-new-pkgs -y -o Dpkg::Options::=--force-confold
  else
    skip "not upgrading"
  fi
fi

# -------------------------------------------------------------- 3. packages --

if want packages; then
  apt_install "${SYSTEM_PACKAGES[@]}"
fi

# ------------------------------------------------------------- 4. tailscale --

if want tailscale; then
  add_apt_repo tailscale \
    "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
    "deb [signed-by=@KEYRING@] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main" \
    tailscale-archive-keyring
  apt_install tailscale

  if ts_logged_in; then
    skip "tailscale is up ($(tailscale ip -4 2>/dev/null | head -1))"
  elif (( DO_TS_UP )) && (( ! CHECK_ONLY )); then
    if [[ -t 0 ]]; then
      # Not via `run`: it prints a URL and blocks until you authorise.
      log "running 'tailscale up' -- follow the URL it prints"
      $SUDO tailscale up || warn "tailscale up did not complete"
    else
      NEED_TS_UP=1
    fi
  else
    NEED_TS_UP=1
  fi
fi

# ------------------------------------------------------------------ 5. mosh --

if want mosh; then
  apt_install mosh
  # mosh refuses to start without a UTF-8 native charset. sshd's
  # `AcceptEnv LANG LC_*` lets a client push a locale the server never
  # generated, producing "mosh-server needs a UTF-8 native character set" on a
  # box where plain ssh works fine.
  if locale -a 2>/dev/null | grep -qiE 'en_US\.utf-?8|C\.utf-?8'; then
    skip "a UTF-8 locale is present, mosh will start"
  else
    log "generating en_US.UTF-8 so mosh can start"
    apt_install locales
    run $SUDO locale-gen en_US.UTF-8
    run $SUDO update-locale LANG=en_US.UTF-8
  fi
fi

# ----------------------------------------------------------------- 6. nvidia --

if want nvidia; then
  if have_pkg "$NVIDIA_DRIVER_PKG" && gpu_ready && (( ! FORCE_NVIDIA )); then
    skip "$NVIDIA_DRIVER_PKG $(nvidia_pkg_version) installed and loaded, $(nvidia-smi -L 2>/dev/null | wc -l) GPU(s)"
  else
    if have_pkg "$NVIDIA_DRIVER_PKG" && ! gpu_ready; then
      warn "$NVIDIA_DRIVER_PKG $(nvidia_pkg_version) is installed but $(nvidia_running_version 2>/dev/null || echo 'no module') is loaded -- a reboot is needed"
    fi
    # A deliberate driver change means unholding first.
    if apt-mark showhold 2>/dev/null | grep -q '^nvidia-'; then
      log "unholding nvidia packages for a deliberate change"
      run $SUDO apt-mark unhold $(apt-mark showhold | grep -E '^(nvidia-|libnvidia-)')
    fi
    apt_install "$NVIDIA_DRIVER_PKG" "${NVIDIA_EXTRA_PKGS[@]}"
    if (( ! CHECK_ONLY )) && ! nvidia_dkms_ok; then
      warn "dkms has NOT built the nvidia module for $(uname -r)."
      warn "Check before rebooting:  dkms status; cat /var/lib/dkms/nvidia/*/build/make.log"
    fi
  fi

  if (( DO_HOLD_NVIDIA )); then
    # The metapackage's deps are unversioned, so holding it alone still lets
    # libnvidia-* move underneath and desync from the loaded module.
    mapfile -t _held < <(dpkg -l | awk '/^ii +(nvidia-|libnvidia-)/{print $2}')
    if (( ${#_held[@]} )); then
      log "holding ${#_held[@]} nvidia packages against apt upgrade"
      run $SUDO apt-mark hold "${_held[@]}"
    fi
  elif apt-mark showhold 2>/dev/null | grep -q '^nvidia-'; then
    skip "nvidia packages already held ($(apt-mark showhold | grep -c -E '^(nvidia-|libnvidia-)') packages)"
  fi
fi

# ----------------------------------------------------------------- 7. docker --

if want docker && (( DO_DOCKER )); then
  add_apt_repo docker \
    "https://download.docker.com/linux/ubuntu/gpg" \
    "deb [arch=${ARCH} signed-by=@KEYRING@] https://download.docker.com/linux/ubuntu ${CODENAME} stable"
  apt_install "${DOCKER_PACKAGES[@]}"

  # Refuse to plant a root-owned image store inside somebody's home directory:
  # `deluser --remove-home` would then take every image with it.
  if [[ -n "$DOCKER_DATA_ROOT" ]]; then
    [[ "$DOCKER_DATA_ROOT" == /* ]] || die "--data-root must be an absolute path"
    while IFS=: read -r _u _x _uid _g _c _home _s; do
      (( _uid >= 1000 )) && [[ -n "$_home" && "$_home" != "/" ]] \
        && [[ "$DOCKER_DATA_ROOT" == "$_home" || "$DOCKER_DATA_ROOT" == "$_home"/* ]] \
        && die "refusing: $DOCKER_DATA_ROOT is inside $_u's home ($_home).
   Deleting that account would delete every image. Pick a path outside /home."
    done < <(getent passwd)
    run $SUDO install -d -m 0710 -o root -g root "$DOCKER_DATA_ROOT"
  fi

  # Detect, do not migrate: an interrupted copy, or one that loses hardlinks or
  # xattrs, corrupts the overlay2 store silently.
  SKIP_DAEMON_JSON=0
  _current_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [[ -n "$DOCKER_DATA_ROOT" && -n "$_current_root" \
        && "$_current_root" != "$DOCKER_DATA_ROOT" \
        && -n "$(docker image ls -q 2>/dev/null)" ]]; then
    warn "docker runs with data-root=$_current_root and already holds images."
    warn "This script will NOT move them. Do it deliberately:"
    warn "    sudo systemctl stop docker docker.socket   # the SOCKET too"
    warn "    sudo rsync -aHAX --numeric-ids $_current_root/ $DOCKER_DATA_ROOT/"
    warn "    sudo mv $_current_root ${_current_root}.old"
    warn "    # re-run this script, verify, THEN delete .old"
    SKIP_DAEMON_JSON=1
  fi

  if (( ! SKIP_DAEMON_JSON )); then
    # Generated whole and compared, rather than also running `nvidia-ctk runtime
    # configure`: two tools rewriting the same JSON never converge.
    _dj="$TMPD/daemon.json"
    { printf '{\n'
      if (( DO_NVCTK )) || have_nvctk; then
        printf '  "runtimes": {\n    "nvidia": {\n      "args": [],\n      "path": "nvidia-container-runtime"\n    }\n  },\n'
      fi
      printf '  "default-shm-size": "%s",\n' "$DOCKER_SHM_SIZE"
      printf '  "default-ulimits": {\n    "memlock": { "Name": "memlock", "Hard": -1, "Soft": -1 }\n  }'
      [[ -n "$DOCKER_DATA_ROOT" ]] && printf ',\n  "data-root": "%s"' "$DOCKER_DATA_ROOT"
      printf '\n}\n'
    } >"$_dj"

    if cmp -s "$_dj" /etc/docker/daemon.json; then
      skip "/etc/docker/daemon.json already current"
    else
      backup /etc/docker/daemon.json
      log "writing /etc/docker/daemon.json"
      run $SUDO install -D -m 0644 -o root -g root "$_dj" /etc/docker/daemon.json
      DOCKER_NEEDS_RESTART=1
    fi
  fi

  run $SUDO systemctl enable --now docker

  if [[ -n "${DOCKER_NEEDS_RESTART:-}" ]]; then
    if [[ -n "$(docker ps -q 2>/dev/null)" ]]; then
      warn "daemon.json changed but containers are running -- not restarting docker."
      warn "Restart it yourself when convenient:  sudo systemctl restart docker"
    else
      log "restarting docker to pick up daemon.json"
      run $SUDO systemctl restart docker
    fi
  fi

  if id -nG "$DOCKER_GROUP_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    skip "$DOCKER_GROUP_USER is already in the docker group"
  else
    log "adding $DOCKER_GROUP_USER to the docker group (root-equivalent access)"
    run $SUDO usermod -aG docker "$DOCKER_GROUP_USER"
    NEED_NEWGRP=1
  fi
fi

# ------------------------------------------------------------------ 8. nvctk --

if want nvctk && (( DO_NVCTK )); then
  have_docker || (( CHECK_ONLY )) || die "the container toolkit needs docker; add --docker"
  # NOTE the single quotes: $(ARCH) is apt's OWN substitution, evaluated when
  # apt reads the file. Let bash expand it and you get an empty path and a 404.
  add_apt_repo nvidia-container-toolkit \
    "https://nvidia.github.io/libnvidia-container/gpgkey" \
    'deb [signed-by=@KEYRING@] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /'
  apt_install "${NVCTK_PACKAGES[@]}"

  # Packages install fine without a driver; only the verification needs one.
  if gpu_ready; then
    if (( CHECK_ONLY )) || $SUDO nvidia-container-cli info >/dev/null 2>&1; then
      log "nvidia-container-cli sees the GPUs"
    else
      warn "nvidia-container-cli cannot see the GPUs; containers will not get them"
    fi
  else
    defer "verify the container runtime sees the GPUs (nvidia-container-cli info)"
  fi
fi

# --------------------------------------------------------------- 9. gpustate --

if want gpustate && [[ -z "${SKIP_GPUSTATE:-}" ]]; then
  _cap_line=""
  [[ -n "$GPU_POWER_CAP" ]] && _cap_line="ExecStart=/usr/bin/nvidia-smi -pl $GPU_POWER_CAP"
  _unit="$TMPD/$GPU_STATE_UNIT.service"
  sed "s|__CAP_LINE__|$_cap_line|" "$TEMPLATES/gpu-state.service" >"$_unit"

  if cmp -s "$_unit" "/etc/systemd/system/$GPU_STATE_UNIT.service" && (( ! FORCE_GPUSTATE )); then
    skip "$GPU_STATE_UNIT.service already current"
  else
    backup "/etc/systemd/system/$GPU_STATE_UNIT.service"
    log "installing /etc/systemd/system/$GPU_STATE_UNIT.service (cap: ${GPU_POWER_CAP:-none})"
    run $SUDO install -D -m 0644 -o root -g root "$_unit" "/etc/systemd/system/$GPU_STATE_UNIT.service"
    run $SUDO systemctl daemon-reload
  fi
  run $SUDO systemctl enable "$GPU_STATE_UNIT.service"

  # Enable always; start only with a live driver. Starting it now would leave a
  # failed unit on a box that is otherwise fine.
  if gpu_ready; then
    run $SUDO systemctl restart "$GPU_STATE_UNIT.service"
  else
    defer "start $GPU_STATE_UNIT.service (persistence mode) -- needs a live driver"
  fi
fi

# --------------------------------------------------------------- next steps --

echo
if (( CHECK_ONLY )); then
  log "dry run complete, nothing changed."
  exit 0
fi
log "done."
echo

if reboot_pending; then
  warn "A REBOOT IS REQUIRED"
  if have_pkg "$NVIDIA_DRIVER_PKG"; then
    warn "  $NVIDIA_DRIVER_PKG $(nvidia_pkg_version) installed; module $(nvidia_running_version 2>/dev/null || echo 'not loaded')."
    nvidia_dkms_ok && warn "  dkms has built it for $(uname -r)." \
                   || warn "  dkms has NOT built it for $(uname -r) -- investigate before rebooting."
  fi
  warn "    sudo reboot"
  warn "    cd $SCRIPT_DIR && ./provision-ubuntu-server.sh"
  warn "  The second run skips what is done and finishes the deferred items. Re-running is safe."
  echo
fi

if (( ${#DEFERRED[@]} )); then
  warn "deferred (${#DEFERRED[@]}), completed by re-running after the reboot:"
  for _d in "${DEFERRED[@]}"; do warn "  - $_d"; done
  echo
fi

[[ -n "${NEED_TS_UP:-}" ]] && warn "tailscale is not logged in:  sudo tailscale up"
[[ -n "${NEED_NEWGRP:-}" ]] && {
  warn "$DOCKER_GROUP_USER was added to the docker group -- log out and back in"
  warn "(or run 'newgrp docker') before docker works without sudo."
}

if have_docker; then
  echo
  log "docker: $(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo '/var/lib/docker'), $(df -h --output=avail "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" 2>/dev/null | tail -1 | tr -d ' ') free"
  log "test it:      docker run --rm hello-world"
  have_nvctk && log "test the GPUs: docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi"
  echo
  warn "docker publishes ports BELOW any firewall: '-p 8000:8000' is reachable"
  warn "from your whole LAN. Bind explicitly instead:"
  warn "    -p 127.0.0.1:8000:8000        this host only"
  warn "    -p \$(tailscale ip -4):8000:8000   tailnet only"
fi

if gpu_ready; then
  echo
  log "GPUs: $(nvidia-smi -L 2>/dev/null | wc -l), persistence $(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1), cap ${GPU_POWER_CAP:-stock}"
  log "live changes: gpu-power (from the account repo);  persistent: GPU_POWER_CAP + --only gpustate"
fi

echo
log "next: provision each user account"
echo "    git clone https://github.com/prairie-guy/provision-ubuntu-account.git ~/stuff/provision-ubuntu-account"
echo "    ~/stuff/provision-ubuntu-account/provision-ubuntu-account.sh"

if (( DO_REBOOT )); then
  if have_pkg "$NVIDIA_DRIVER_PKG" && ! nvidia_dkms_ok; then
    warn "dkms has NOT built the nvidia module for $(uname -r) -- refusing to reboot"
    warn "automatically. Check: dkms status"
  else
    echo; log "rebooting in 10s (Ctrl-C to cancel)"; sleep 10; $SUDO reboot
  fi
fi
exit 0
