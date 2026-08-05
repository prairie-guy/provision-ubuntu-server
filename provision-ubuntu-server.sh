#!/usr/bin/env bash
#
# provision-ubuntu-server.sh -- provision the SYSTEM, not a user account.
#
# Everything here needs root and applies to the whole machine. Run it once per
# box, before provision-ubuntu-account.sh is run for each user. Its main job is
# to install the system packages both of those need, so no per-account run ever
# escalates to sudo.
#
# THERE ARE THREE COMMANDS. That is the whole interface:
#
#   ./provision-ubuntu-server.sh             ask, then do it
#   ./provision-ubuntu-server.sh --dry-run   ask, then print what it would do
#   ./provision-ubuntu-server.sh doctor      check this box, offer fixes
#
# It asks a plain question about each thing it could do, phrased by what it
# actually found on the box, and asks ALL of them before doing any work. Then it
# runs to completion without stopping -- sudo is primed during the questions and
# kept warm, so not even a driver install pauses for a password. Press Enter
# through everything for the conservative answer.
#
# There are no other options, deliberately. Anything consequential enough to
# want a flag is consequential enough to be asked about, and anything that is a
# VALUE rather than a decision -- which driver branch, where docker keeps
# images, the per-GPU power cap -- lives in the CONFIGURATION block below, where
# it carries a comment saying why it is what it is.
#
# Idempotent: safe to re-run, and re-running is how you change things later.
#
# The nvidia driver is HELD (pinned). Neither apt, nor unattended-upgrades, nor
# a re-run of this script will move it. It changes only when you say so, at the
# driver question, which shows what is installed and which branches exist and
# lets you type a different one. Enter keeps what you have.
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
# Leave this much of the volume group unallocated for snapshot CoW space and
# take the rest. ABSOLUTE, not a percentage: snapshot headroom depends on how
# much is written while a snapshot exists, not on how large the disk is. A
# percentage under-reserves on a small disk and wastes terabytes on a large one.
# Accepts a numfmt suffix (100G, 512M) or plain bytes. 0 takes everything.
GROW_RESERVE="${GROW_RESERVE:-100G}"            # left unallocated in the VG
GROW_MIN_BYTES=$((1024*1024*1024))              # below this, not worth resizing

# --- system packages --------------------------------------------------------
# The UNION of what provision-ubuntu-account.sh and ~/.config/doom/setup.sh
# install. Both probe with dpkg-query first, so once these exist neither ever
# calls sudo again -- which is the entire point of installing them here.
# ADDING a line is safe. REMOVING one makes some later per-account run escalate
# to sudo, which a non-sudo account cannot do.
SYSTEM_PACKAGES=(
  git curl wget bc less        # account script
  openssh-client               # account script: ssh-keygen + the ssh git clone
  ca-certificates gnupg        # required by add_apt_repo below
  emacs-nox                    # doom's setup.sh installs this itself; without
                               # it the FIRST account run escalates to sudo
  ripgrep fd-find              # doom: completion/projectile
  aspell aspell-en             # doom: :checkers spell
  pandoc                       # doom: org/markdown export
  build-essential              # doom: compiles vterm + tree-sitter grammars
  libvterm-dev pkg-config      # doom: :term vterm needs all four of these
  cmake libtool-bin
  uidmap                       # rootless docker: newuidmap/newgidmap
  unzip zip                    # archives -- nothing else provides these
  rsync                        # this script's own data-root advice uses it
  pigz                         # parallel gzip; gzip uses 1 of 48 cores here
  pv                           # progress on multi-GB copies
  p7zip-full                   # 7z, which tar and unzip cannot read
)

# --- identity ---------------------------------------------------------------
# Prompted for, defaulting to the current hostname. Set BEFORE the tailscale
# step: tailscale takes its device name from the hostname at registration, so
# renaming afterwards means the tailnet keeps showing the old name.
SYSTEM_HOSTNAME="${SYSTEM_HOSTNAME:-}"          # empty = you are asked

# Accounts that run GPU containers via ROOTLESS docker. A rootless daemon runs
# as the account and so cannot raise the account's own memlock hard limit --
# it has to be raised here, at the system level, or CUDA pinned-memory and NCCL
# allocations fail inside its containers. Empty = install nothing.
MEMLOCK_ACCOUNTS="${MEMLOCK_ACCOUNTS:-}"        # "a b" -- empty = none

# Accounts that will run `provision-ubuntu-account.sh --docker-rootless`.
# That script runs AS the account and never calls sudo -- that contract is what
# lets a non-sudo agent account provision itself completely -- so the parts of
# rootless setup that genuinely need root have to be done HERE:
#
#   * uidmap + docker-ce-rootless-extras  (already in SYSTEM_PACKAGES and
#                                          DOCKER_PACKAGES; nothing to add)
#   * a /etc/subuid + /etc/subgid range   (adduser writes one, useradd does not)
#   * loginctl enable-linger              (or the account's daemon, and every
#                                          container under it, dies when its
#                                          last session ends)
#   * NOT being in the docker group       (root-equivalent, and the rootless
#                                          setup tool refuses to run beside a
#                                          writable /var/run/docker.sock)
#
# Empty = prompted for when docker is present, then skipped if left blank.
ROOTLESS_ACCOUNTS="${ROOTLESS_ACCOUNTS:-}"      # "a b" -- empty = you are asked

# --- gpu --------------------------------------------------------------------
# `ubuntu-drivers devices` reports this as `recommended` for these exact cards,
# and it is NEWER than the 590.48 the rtx6kpro community wiki validated. 610 is
# available in the same repo but is a New Feature Branch, unvalidated on this
# hardware. Move only when a container needs CUDA above this driver's ceiling:
# or just type the branch number at the driver question.
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
# sweeping your own workload. To try it: set this, then re-run.
# For a LIVE, non-persistent change use `gpu-power` from the account repo.
GPU_POWER_CAP="${GPU_POWER_CAP:-}"              # watts, empty = stock 600W
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
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-}"        # empty = /var/lib/docker

# Shared memory and locked-memory defaults for every container. Multi-GPU NCCL
# hangs or dies with cryptic OOMs when these are left at docker's defaults, and
# the rtx6kpro wiki lists --shm-size and --ulimit memlock=-1 as required for
# vLLM on these cards. Setting them daemon-side means you cannot forget them.
DOCKER_SHM_SIZE="${DOCKER_SHM_SIZE:-16G}"

# Account added to the `docker` group. Membership is root-equivalent -- you can
# bind-mount / into a container -- so this is the invoking human, not everyone.
DOCKER_GROUP_USER="${DOCKER_GROUP_USER:-${SUDO_USER:-$(id -un)}}"   # ROOT-EQUIVALENT

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

# Name a file this run is about to replace, and where its backup goes -- the
# same format and the same promise as the account script. Answering yes to
# something that rewrites a file under /etc should not require trusting the
# script about which file it meant.
list_replace() {
  local f
  for f in "$@"; do
    printf '      \033[1mREPLACE\033[0m %-44s backup: %s\n' "$f" "$(basename "$f").bak-$STAMP"
  done
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
  # APT_STALE must be tested FIRST: a repo added later in the run needs indexing
  # even though an update already happened, or `apt install docker-ce` fails
  # with "Unable to locate package".
  (( APT_UPDATED )) && (( ! APT_STALE )) && return 0
  if (( ! APT_STALE )) \
     && [[ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -newermt '-1 hour' -print -quit 2>/dev/null)" ]]; then
    skip "apt lists are less than an hour old"
    APT_UPDATED=1; return 0
  fi
  log "apt-get update"
  run $SUDO apt-get update -qq
  APT_UPDATED=1; APT_STALE=0
}

# dpkg's Status is three words: "<desired> ok <state>". HOLDING a package changes
# the FIRST word to `hold`, so matching the whole string reports every held
# package as missing. That is not cosmetic: it made a routine run decide the
# nvidia driver was absent, unhold the whole stack and reinstall it -- the exact
# unattended upgrade the hold exists to prevent. Match on the state instead.
have_pkg() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == *" ok installed" ]]; }

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

# apt_install only installs what is MISSING, so it can never upgrade. A
# deliberate "update it?" answer has to say so explicitly.
apt_upgrade_pkgs() {
  apt_update
  log "upgrading: $*"
  run $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
      apt-get install -y --only-upgrade -o Dpkg::Options::=--force-confold "$@"
  return 0
}

# ------------------------------------------------------------------- args --

# `doctor` is a subcommand, not a flag: it does something different from
# provisioning -- it reports on the box and offers to fix what it finds -- and a
# separate word says that more clearly than a flag alongside the others.
DOCTOR=0; HELP=0
if [[ "${1:-}" == doctor ]]; then DOCTOR=1; shift; fi

# Three things only. Every other decision is a question this script asks, and
# every value it uses is in the CONFIGURATION block above.
#
# The deleted flags were not neutral. --only ran a partial provision, which on
# this box could mean a driver installed with no container toolkit to use it.
# --reinstall answered yes to everything at once, including a driver reinstall
# on a machine serving models. --data-root and --gpu-cap changed where images
# live and how much power the cards draw, from a command line, with no
# confirmation. Values belong in the file, where they carry a comment saying why.
while (( $# )); do
  case "$1" in
    --dry-run)     CHECK_ONLY=1; shift ;;
    -h|--help)     HELP=1; shift ;;
    *) die "unknown argument: $1

   This script takes no options beyond --dry-run and --help.
   To choose what happens, run it and answer the questions:
       ./provision-ubuntu-server.sh
   To change a value (driver branch, data-root, power cap, shm size),
   edit the CONFIGURATION block at the top of the script.
   To see the state of this box and what would change:
       ./provision-ubuntu-server.sh --help
       ./provision-ubuntu-server.sh doctor" ;;
  esac
done

# The steps, in the order they run. Used by --help to describe what a run would
# ask about; every one of them is always reached.
VALID_STEPS=(hostname limits lvm apt packages tailscale mosh nvidia docker nvctk rootless gpustate)
# No --only any more: every step is reached, and what it DOES is decided by the
# question it asked. Kept as a function so the step guards read unchanged.
want() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

# Default to the current name so pressing Enter keeps it.
[[ -n "${SYSTEM_HOSTNAME:-}" ]] && HOSTNAME_EXPLICIT=1 || HOSTNAME_EXPLICIT=0
[[ -n "$SYSTEM_HOSTNAME" ]] || SYSTEM_HOSTNAME="$(hostname)"

[[ -n "$ROOTLESS_ACCOUNTS" ]] && ROOTLESS_EXPLICIT=1 || ROOTLESS_EXPLICIT=0

# Validated here rather than in the step: a typo'd account name should stop the
# run before anything has been changed, not after ten minutes of apt.
for _a in $ROOTLESS_ACCOUNTS; do
  [[ "$_a" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || die "invalid ROOTLESS_ACCOUNTS entry '$_a': not a valid account name"
  getent passwd "$_a" >/dev/null || die "no such account: $_a
   Create it first:  sudo adduser $_a"
done

# GPU_POWER_CAP lands in a sed replacement and in an ExecStart line; a stray | or
# a non-numeric value would corrupt the unit or fail at every boot.
[[ -z "$GPU_POWER_CAP" || "$GPU_POWER_CAP" =~ ^[0-9]+$ ]] \
  || die "invalid GPU_POWER_CAP '$GPU_POWER_CAP': watts must be a whole number"
GROW_RESERVE_B="$(numfmt --from=iec "$GROW_RESERVE" 2>/dev/null)" \
  || die "invalid GROW_RESERVE '$GROW_RESERVE': use bytes or an IEC size like 100G"

[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux"
command -v apt-get >/dev/null || die "apt-get not found; this script targets Ubuntu/Debian"
[[ -d "$TEMPLATES" ]] || die "templates/ not found next to the script"

# ------------------------------------------------------------------- root --

# Unlike the account script this one is a system tool, but it should still be
# invoked by the human rather than `sudo bash` -- so it calls sudo itself.
if [[ $EUID -eq 0 ]]; then
  SUDO=""
  # Without SUDO_USER, DOCKER_GROUP_USER defaulted to `root`, and adding root to
  # the docker group is meaningless. Require an explicit target instead.
  [[ "$DOCKER_GROUP_USER" != root ]] \
    || die "running as root with no SUDO_USER: set DOCKER_GROUP_USER so the
   docker group addition has a target other than root"
else
  command -v sudo >/dev/null || die "sudo not found and not running as root"
  SUDO="sudo"
fi

if (( ! HELP )); then
  (( CHECK_ONLY )) && warn "DRY RUN -- nothing will be changed."
  log "host=$(hostname) user=${USER:-$(id -un)} kernel=$(uname -r)"
fi

# Prime sudo BEFORE the questions: lvs/vgs need root, so the LVM question
# cannot even be composed without it. Keep the credential warm afterwards --
# sudo's cache is 15 minutes and a full run outlasts it, which would otherwise
# stop for a password long after you walked away.
# --help only reads; doctor only reads until you accept a fix, and its fixes
# prompt for their own sudo when you say yes. Neither should demand a password
# up front -- that would make looking at the box more intrusive than it is.
if [[ -n "$SUDO" ]] && (( ! HELP && ! DOCTOR )); then
  if (( CHECK_ONLY )); then
    # Do not prompt during a dry run; degrade gracefully instead.
    sudo -n true 2>/dev/null || warn "--dry-run has no cached sudo: LVM state cannot be read, that step will report unknown"
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
# No pipeline: `dkms status | grep -q` looks correct and is not. grep -q exits at
# the first match, dkms takes SIGPIPE writing the next line, and `set -o pipefail`
# turns that into a failed pipeline -- so this returned FALSE on a box where the
# module was built fine. That made --reboot refuse to reboot, and made the nvidia
# step warn that dkms had failed when it had not.
nvidia_dkms_ok() {
  local line kver
  kver="$(uname -r)"
  while IFS= read -r line; do
    if [[ "$line" == *", $kver, "*": installed" ]]; then return 0; fi
  done < <(dkms status -m nvidia 2>/dev/null)
  return 1
}

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

# Subordinate uid/gid ranges, for the rootless step. adduser allocates one per
# account; this only has to cover accounts made with plain useradd, or made
# before subids were a thing. The next free block is SCANNED rather than
# hardcoded to 100000: two accounts sharing a range means one account's
# containers can write files owned by the other's.
SUBID_COUNT="$(awk '$1=="SUB_UID_COUNT"{print $2}' /etc/login.defs 2>/dev/null | tail -1)"
[[ "$SUBID_COUNT" =~ ^[0-9]+$ ]] || SUBID_COUNT=65536
next_subid() {
  local f="$1" name start count max=100000
  [[ -f "$f" ]] || { printf '%s' "$max"; return 0; }
  while IFS=: read -r name start count; do
    [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || continue
    if (( start + count > max )); then max=$(( start + count )); fi
  done <"$f"
  printf '%s' "$max"
}
has_subid()  { grep -q "^$1:" "$2" 2>/dev/null; }
# No pipeline: under `set -o pipefail`, `id -nG | grep -q` can report failure
# when grep exits early and the writer takes SIGPIPE. A false "not in the docker
# group" here would silently skip the revocation, which is the security-relevant
# half of the whole step.
in_docker_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" docker "* ]]; }

# Installed vs available, so a question can say whether there is ACTUALLY
# anything to update instead of asking "update it?" about a current package.
# Both read apt's cached metadata -- no network, so this is cheap enough to run
# during the questions. Cached means possibly stale; `doctor` reports the age.
pkg_installed_ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
pkg_candidate_ver() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'; }
# True only when a NEWER version exists. Same version, no candidate, or a
# downgrade all count as "nothing to do".
pkg_upgradable() {
  local i c
  i="$(pkg_installed_ver "$1")"; [[ -n "$i" ]] || return 1
  c="$(pkg_candidate_ver "$1")"; [[ -n "$c" && "$c" != "(none)" ]] || return 1
  dpkg --compare-versions "$c" gt "$i"
}
# How stale apt's package lists are, in days. A candidate version read from
# metadata last refreshed a month ago is not evidence that nothing is available.
apt_meta_age_days() {
  local newest
  newest="$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
  [[ -n "$newest" ]] || { printf '999'; return 0; }
  printf '%d' "$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))"
}

# Exists in the configured repos at all -- checked before offering to switch to
# a driver branch, so a typo fails at the question rather than mid-apt.
have_pkg_available() { [[ -n "$(pkg_candidate_ver "$1")" && "$(pkg_candidate_ver "$1")" != "(none)" ]]; }

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
  # As root SUDO is empty, and `$SUDO -n true` would expand to `-n true`.
  if [[ -n "$SUDO" ]]; then
    sudo -n true 2>/dev/null || { LVM_WHY="need root to read LVM state"; return 1; }
  fi

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

  # Take everything above the reserve. Exact, not rounded to a percentage.
  LVM_ADD_B=$(( LVM_FREE_B - GROW_RESERVE_B ))
  (( LVM_ADD_B >= GROW_MIN_BYTES )) \
    || { LVM_WHY="only $(hb "$LVM_FREE_B") unallocated in $LVM_VG, and $(hb "$GROW_RESERVE_B") is reserved -- nothing worth growing"; return 1; }
  LVM_OK=1
}

# -------------------------------------------------------------------- help --

# Deliberately verbose, and it reports LIVE state rather than only static text.
# These commands change a machine that may be serving models, so --help should
# answer "what would this actually do to THIS box right now", not just list
# flags. In particular it names what has an update waiting, so you never have to
# start a run to find out whether there is anything to do.
if (( HELP )); then
  sed -n '2,34p' "$0" | sed 's/^# \?//'
  printf '\033[1mSTATE OF THIS BOX\033[0m\n\n'
  printf '  apt package lists: %sd old\n' "$(apt_meta_age_days)"

  if have_pkg "$NVIDIA_DRIVER_PKG"; then
    printf '  nvidia driver:     %s %s (%s packages held)\n' \
      "$NVIDIA_DRIVER_PKG" "$(nvidia_pkg_version)" \
      "$(apt-mark showhold 2>/dev/null | grep -cE '^(nvidia-|libnvidia-)' || true)"
    if pkg_upgradable "$NVIDIA_DRIVER_PKG"; then
      printf '                     \033[1m%s is available\033[0m -- held, so NOT automatic\n' \
        "$(pkg_candidate_ver "$NVIDIA_DRIVER_PKG")"
    fi
  else
    printf '  nvidia driver:     not installed\n'
  fi

  # One line per component that apt can move, so "is there anything to update?"
  # is answered here rather than by starting a run.
  printf '\n  \033[1mupdates available\033[0m (these are what a run would offer):\n'
  _any_upd=0
  for _p in docker-ce nvidia-container-toolkit tailscale mosh; do
    if have_pkg "$_p"; then
      if pkg_upgradable "$_p"; then
        printf '    %-28s %s -> \033[1m%s\033[0m\n' "$_p" "$(pkg_installed_ver "$_p")" "$(pkg_candidate_ver "$_p")"
        _any_upd=1
      fi
    fi
  done
  _sysupd="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
  if (( _sysupd )); then
    printf '    %-28s %s package(s)\n' "system packages (apt)" "$_sysupd"; _any_upd=1
  fi
  (( _any_upd )) || printf '    nothing -- every managed component is current\n'

  printf '\n\033[1mWHAT A RUN WOULD ASK ABOUT\033[0m\n\n'
  printf '  One question each, in this order, phrased by what is already there.\n'
  printf '  Anything already done is reported and skipped, not asked about again.\n\n'
  printf '    %-12s %s\n' \
    hostname  "the system hostname (asked before tailscale registers a name)" \
    limits    "memlock for named accounts (MEMLOCK_ACCOUNTS)" \
    lvm       "grow / into unallocated VG space -- asked, default no" \
    apt       "apt update + upgrade, if anything is upgradable" \
    packages  "${#SYSTEM_PACKAGES[@]} system packages both scripts need" \
    tailscale "install + tailscale up (interactive browser login)" \
    mosh      "mosh, and a UTF-8 locale for it" \
    nvidia    "the driver: shows what is installed, held and available;" \
    ""        "  type a branch number to switch, Enter to keep" \
    docker    "Docker Engine from Docker's own repo, and daemon.json" \
    nvctk     "NVIDIA Container Toolkit, so containers see the GPUs" \
    rootless  "docker for named accounts WITHOUT the root-equivalent group" \
    gpustate  "a systemd unit setting GPU persistence mode at boot"

  printf '\n\033[1mWHAT YOU CAN CHANGE, AND WHERE\033[0m\n\n'
  printf '  There are no options for these. Edit the CONFIGURATION block at the top\n'
  printf '  of %s -- each carries a comment explaining the\n' "$(basename "$0")"
  printf '  choice. They are properties of this machine, not per-run decisions.\n\n'
  printf '    %-22s %s\n' \
    "NVIDIA_DRIVER_PKG" "$NVIDIA_DRIVER_PKG   (also choosable at the driver question)" \
    "DOCKER_DATA_ROOT"  "${DOCKER_DATA_ROOT:-/var/lib/docker (docker default)}" \
    "DOCKER_SHM_SIZE"   "$DOCKER_SHM_SIZE   (NCCL dies at docker's 64M default)" \
    "DOCKER_GROUP_USER" "$DOCKER_GROUP_USER   -- gets ROOT-EQUIVALENT docker access" \
    "GPU_POWER_CAP"     "${GPU_POWER_CAP:-none -- each card at its stock 600W}" \
    "GROW_RESERVE"      "$GROW_RESERVE   left unallocated in the VG for snapshots" \
    "MEMLOCK_ACCOUNTS"  "${MEMLOCK_ACCOUNTS:-none}" \
    "ROOTLESS_ACCOUNTS" "${ROOTLESS_ACCOUNTS:-none set -- you are asked at the prompt}" \
    "SYSTEM_PACKAGES"   "${#SYSTEM_PACKAGES[@]} packages -- adding a line is safe, removing one" \
    ""                  "  makes some later per-account run need sudo"

  printf '\n\033[1mWHAT IT WILL NOT DO\033[0m\n\n'
  printf '  move the nvidia driver unless you ask at the driver question\n'
  printf '  migrate docker'"'"'s image store -- it adopts what is there and says so\n'
  printf '  restart docker while containers are running -- it warns instead\n'
  printf '  overwrite a config file without a NAME.bak-<timestamp> copy first\n'
  printf '  delete anything: this script has no rm outside its own temp directory\n'
  printf '  reboot on its own -- it tells you when one is needed\n\n'
  exit 0
fi

# ------------------------------------------------------------------ doctor --

# Reports on the box, then offers to fix what it can. Read-only until you say
# yes: every check runs first and the whole report prints, so you see the full
# picture before deciding anything.
#
# A problem that CANNOT be fixed from here is still reported, with the command
# that would fix it. Staying silent about a finding because there is no button
# for it is worse than showing it.
DOC_OK=0; DOC_WARN=0; DOC_FAIL=0
DOC_FIX_DESC=(); DOC_FIX_CMD=()
doc_ok()   { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; DOC_OK=$((DOC_OK+1)); }
doc_warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; DOC_WARN=$((DOC_WARN+1)); }
doc_fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; DOC_FAIL=$((DOC_FAIL+1)); }
doc_note() { printf '        \033[2m%s\033[0m\n' "$*"; }
# Queue a fix for the end. An EMPTY description means "reportable, not fixable
# from here" -- the command is printed for you to run yourself.
doc_fix()  { DOC_FIX_DESC+=("$1"); DOC_FIX_CMD+=("$2"); }

if (( DOCTOR )); then
  printf '\n'
  log "doctor: $(hostname) -- $(. /etc/os-release && printf '%s' "$PRETTY_NAME"), kernel $(uname -r)"
  printf '\n'

  # Everything below that says "current" is only as good as apt's metadata, so
  # its age is reported first rather than quietly assumed to be fresh.
  _age="$(apt_meta_age_days)"
  if (( _age <= 7 )); then
    doc_ok "apt package lists are ${_age}d old"
  else
    doc_warn "apt package lists are ${_age}d old -- 'available' versions may be stale"
    doc_fix "refresh apt package lists" "$SUDO apt-get update"
  fi

  # --- nvidia: the driver moving unnoticed is the failure this box cares most
  # --- about, so held, loaded and dkms are checked separately.
  if have_pkg "$NVIDIA_DRIVER_PKG"; then
    _nheld="$(apt-mark showhold 2>/dev/null | grep -cE '^(nvidia-|libnvidia-)' || true)"
    if (( _nheld )); then
      doc_ok "nvidia $(nvidia_pkg_version) held ($_nheld packages) -- apt cannot move it"
    else
      doc_fail "nvidia packages are NOT held"
      doc_note "unattended-upgrades can move libnvidia-* under the loaded module,"
      doc_note "detaching the GPUs from every running container"
      doc_fix "hold the nvidia packages" "$SCRIPT_DIR/provision-ubuntu-server.sh"
    fi
    if gpu_ready; then
      doc_ok "driver $(nvidia_running_version) loaded, $(nvidia-smi -L 2>/dev/null | wc -l) GPU(s) visible"
    else
      doc_fail "the nvidia module is not loaded ($(nvidia_running_version 2>/dev/null || echo none))"
      doc_note "installed package is $(nvidia_pkg_version) -- a reboot is needed"
      doc_fix "" "sudo reboot"
    fi
    if nvidia_dkms_ok; then
      doc_ok "dkms has built the module for $(uname -r)"
    else
      doc_fail "dkms has NOT built the nvidia module for the running kernel"
      doc_note "a kernel upgrade whose rebuild failed takes every GPU down at the next reboot"
      doc_note "check: dkms status; cat /var/lib/dkms/nvidia/*/build/make.log"
      doc_fix "" "sudo dkms autoinstall"
    fi
    if pkg_upgradable "$NVIDIA_DRIVER_PKG"; then
      doc_note "note: $(pkg_candidate_ver "$NVIDIA_DRIVER_PKG") is available on this branch"
      doc_note "the hold means it will NOT be taken automatically"
    fi
  else
    doc_warn "$NVIDIA_DRIVER_PKG is not installed"
  fi

  if have_gpustate; then
    if systemctl is-enabled "$GPU_STATE_UNIT.service" >/dev/null 2>&1; then
      doc_ok "$GPU_STATE_UNIT.service enabled"
    else
      doc_fail "$GPU_STATE_UNIT.service is installed but not enabled"
      doc_fix "enable $GPU_STATE_UNIT.service" "$SUDO systemctl enable --now $GPU_STATE_UNIT.service"
    fi
    if gpu_ready; then
      _pm="$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ' ')"
      if [[ "$_pm" == *Enabled* && "$_pm" != *Disabled* ]]; then
        doc_ok "persistence mode enabled on all GPUs"
      else
        doc_warn "persistence mode: $_pm"
      fi
    fi
  elif gpu_ready; then
    doc_warn "no $GPU_STATE_UNIT.service -- persistence mode is not set at boot"
    doc_fix "install the GPU state unit" "$SCRIPT_DIR/provision-ubuntu-server.sh"
  fi

  # --- docker: unbounded logs fill / on a box running a long-lived server, and
  # --- nothing surfaces it until it happens.
  if have_docker; then
    _droot="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || $SUDO docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo 'unknown (needs docker access)')"
    doc_ok "docker $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1), data-root $_droot"
    if [[ -f /etc/docker/daemon.json ]] && grep -q 'max-size' /etc/docker/daemon.json 2>/dev/null; then
      doc_ok "docker log rotation configured"
    else
      doc_fail "docker has NO log rotation -- the json-file driver is unbounded"
      doc_note "a long-running container writing progress lines will fill /"
      doc_fix "write /etc/docker/daemon.json" "$SCRIPT_DIR/provision-ubuntu-server.sh"
    fi
    if pkg_upgradable docker-ce; then
      doc_note "note: docker-ce $(pkg_candidate_ver docker-ce) is available"
    fi
    # The docker group is root-equivalent. Name who holds it rather than leaving
    # it to be discovered.
    _dgroup="$(getent group docker | cut -d: -f4)"
    if [[ -n "$_dgroup" ]]; then
      doc_warn "in the docker group, which is ROOT-EQUIVALENT: $_dgroup"
      doc_note "a member can bind-mount / into a container and read every credential"
    else
      doc_ok "nobody is in the docker group"
    fi
  fi

  # --- rootless accounts: each piece breaks separately, and each is invisible
  # --- until a container fails to start.
  _unreadable=""
  while IFS=: read -r _u _x _uid _g _c _home _s; do
    (( _uid >= 1000 && _uid < 65534 )) || continue
    # Homes are 0750. Silently finding nothing in an unreadable home reads as
    # "this account is fine", which is the one thing it must not mean.
    if [[ ! -r "$_home" ]]; then _unreadable="$_unreadable $_u"; continue; fi
    [[ -f "$_home/.config/systemd/user/docker.service" ]] || continue
    doc_ok "$_u has a rootless docker daemon"
    if has_subid "$_u" /etc/subuid && has_subid "$_u" /etc/subgid; then
      : # ranges present, nothing to say
    else
      doc_fail "$_u has no subuid/subgid range -- its rootless daemon cannot start"
      _s1="$(next_subid /etc/subuid)"; _s2="$(next_subid /etc/subgid)"
      doc_fix "add a subordinate id range for $_u" \
        "$SUDO usermod --add-subuids $_s1-$((_s1+SUBID_COUNT-1)) --add-subgids $_s2-$((_s2+SUBID_COUNT-1)) $_u"
    fi
    if [[ "$(loginctl show-user "$_u" -p Linger --value 2>/dev/null)" == yes ]]; then
      doc_ok "$_u has linger enabled -- its daemon survives logout"
    else
      doc_fail "$_u has NO linger -- its daemon and containers die at its last logout"
      doc_fix "enable linger for $_u" "$SUDO loginctl enable-linger $_u"
    fi
    if in_docker_group "$_u"; then
      doc_fail "$_u is rootless AND in the root-equivalent docker group"
      doc_note "the rootful socket stays reachable, so rootless buys nothing"
      doc_fix "remove $_u from the docker group" "$SUDO gpasswd -d $_u docker"
    fi
    if [[ -f "$_home/.config/docker/daemon.json" ]]; then
      doc_ok "$_u has its own daemon.json (log rotation, shm, memlock)"
    else
      doc_warn "$_u has no ~/.config/docker/daemon.json"
      doc_note "a rootless daemon reads NOTHING from /etc/docker: no log rotation"
      doc_note "(fills \$HOME), 64M shm, and the account's default memlock"
      doc_fix "" "as $_u:  ./provision-ubuntu-account.sh --docker-rootless"
    fi
  done < <(getent passwd)
  if [[ -n "$_unreadable" ]]; then
    doc_warn "not inspected, home not readable as $(id -un):$_unreadable"
    doc_note "their rootless docker, linger and daemon.json cannot be checked from here"
    doc_note "for a full report:  sudo -v && ./provision-ubuntu-server.sh doctor"
  fi

  if have_tailscale; then
    if ts_logged_in; then
      doc_ok "tailscale up ($(tailscale ip -4 2>/dev/null | head -1))"
    else
      doc_warn "tailscale is installed but not logged in"
      doc_fix "log in to tailscale" "$SUDO tailscale up"
    fi
  fi

  if reboot_pending; then
    doc_warn "a reboot is pending"
    doc_fix "" "sudo reboot"
  fi

  printf '\n'
  log "$DOC_OK ok, $DOC_WARN warning(s), $DOC_FAIL failure(s)"

  # Offer each fix individually. Nothing above this point changed anything.
  if (( ${#DOC_FIX_CMD[@]} )); then
    printf '\n'
    for _i in "${!DOC_FIX_CMD[@]}"; do
      if [[ -z "${DOC_FIX_DESC[$_i]}" ]]; then
        warn "not fixable from here:  ${DOC_FIX_CMD[$_i]}"
        continue
      fi
      printf '\n  %s\n      \033[2m%s\033[0m\n' "${DOC_FIX_DESC[$_i]}" "${DOC_FIX_CMD[$_i]}"
      if (( CHECK_ONLY )); then
        printf '    \033[2m[dry run -- would offer this fix]\033[0m\n'
      elif ask_yn "  run it?" n; then
        eval "${DOC_FIX_CMD[$_i]}" || warn "that fix failed; the rest of the report still stands"
      fi
    done
  fi
  printf '\n'
  (( DOC_FAIL )) && exit 1
  exit 0
fi

# --------------------------------------------------------------- questions --
#
# One question per component, phrased by what is actually there: "install X?"
# when absent, "update X?" when present. Asked here, before any work, so a long
# run never stops for input. A flag already given is taken as the answer.

if want hostname && (( ! HOSTNAME_EXPLICIT )) && [[ -t 0 ]]; then
  read -r -p "hostname [$SYSTEM_HOSTNAME]: " _reply || true
  [[ -n "${_reply:-}" ]] && SYSTEM_HOSTNAME="$_reply"
fi
# RFC 1123: it lands in /etc/hosts and is what tailscale registers.
[[ "$SYSTEM_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
  || die "invalid hostname '$SYSTEM_HOSTNAME': letters, digits and hyphens only, no leading or trailing hyphen"

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
    printf '      would grow by:  %s   (leaving %s reserved)\n' "$(hb "$LVM_ADD_B")" "$(hb "$GROW_RESERVE_B")"
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
    # The driver is the one thing you would deliberately change the version of,
    # so show the whole picture and let a branch be typed here rather than
    # requiring NVIDIA_DRIVER_PKG to be set on the command line.
    printf '\n'
    log "nvidia driver"
    printf '      installed:  %-28s %s\n' "$NVIDIA_DRIVER_PKG $(nvidia_pkg_version)" \
      "$(apt-mark showhold 2>/dev/null | grep -cE '^(nvidia-|libnvidia-)' | sed 's/^/HELD, /;s/$/ packages/')"
    if gpu_ready; then
      printf '      loaded:     %-28s %s GPU(s)\n' "$(nvidia_running_version)" "$(nvidia-smi -L 2>/dev/null | wc -l)"
    else
      printf '      loaded:     %s\n' "$(nvidia_running_version 2>/dev/null || echo 'no module -- a reboot is needed')"
    fi
    # ERE, so [0-9]+ -- not [0-9]\+, which matches a literal plus and finds
    # nothing. `|| true` because an empty result must not abort the run under
    # `set -e`: not knowing the branch list is cosmetic, not fatal.
    _branches="$(apt-cache search --names-only '^nvidia-driver-[0-9]+-open$' 2>/dev/null \
                 | grep -oE '[0-9]+' | sort -nu | tr '\n' ' ' || true)"
    [[ -n "$_branches" ]] && printf '      branches:   %s(-open)\n' "$_branches"
    if pkg_upgradable "$NVIDIA_DRIVER_PKG"; then
      printf '      available:  %s on this branch\n' "$(pkg_candidate_ver "$NVIDIA_DRIVER_PKG")"
    else
      printf '      available:  nothing newer on this branch\n'
    fi
    printf '      a change needs a REBOOT before the new module loads.\n'

    _cur_branch="$(printf '%s' "$NVIDIA_DRIVER_PKG" | grep -oE '[0-9]+' | head -1)"
    if [[ -t 0 ]]; then
      read -r -p "keep $_cur_branch, or type a branch number to switch to [$_cur_branch]: " _reply || true
    else
      _reply=""
    fi
    _reply="${_reply:-$_cur_branch}"
    if [[ "$_reply" != "$_cur_branch" ]]; then
      [[ "$_reply" =~ ^[0-9]+$ ]] || die "not a branch number: '$_reply' (expected e.g. 610)"
      have_pkg_available "nvidia-driver-$_reply-open" \
        || die "nvidia-driver-$_reply-open is not in the configured apt repos.
   Available: $_branches"
      NVIDIA_DRIVER_PKG="nvidia-driver-$_reply-open"
      log "switching to $NVIDIA_DRIVER_PKG (this unholds, installs, and re-holds)"
      FORCE_NVIDIA=1
    elif (( ! FORCE_NVIDIA )) && pkg_upgradable "$NVIDIA_DRIVER_PKG" \
         && ask_yn "update to $(pkg_candidate_ver "$NVIDIA_DRIVER_PKG") on this branch?" n; then
      FORCE_NVIDIA=1
    fi
  fi
  # Holding matters because the metapackage's deps are UNVERSIONED, so an
  # unattended security update can move libnvidia-* underneath the loaded
  # module and detach the GPUs from a running inference server.
  if [[ -z "$(apt-mark showhold 2>/dev/null | grep '^nvidia-' || true)" ]]; then
    ask_yn "hold the nvidia packages so apt/unattended-upgrades cannot move them?" y && DO_HOLD_NVIDIA=1
  fi
fi

if want docker; then
  if have_docker; then
    # Only ask when apt actually has something newer. "Docker 29.7.1 is
    # installed -- update it?" on a current box is noise: there is nothing to
    # update to, and answering yes does nothing but reinstall the same version.
    if (( ! FORCE_DOCKER )) && pkg_upgradable docker-ce; then
      if ask_yn "Docker $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) is installed; $(pkg_candidate_ver docker-ce | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) is available -- update it?" n; then
        FORCE_DOCKER=1; DO_DOCKER=1
      fi
    elif (( ! FORCE_DOCKER )); then
      skip "Docker $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) is installed and current"
    fi
    DO_DOCKER=1
  elif (( ! DO_DOCKER )); then
    ask_yn "install Docker Engine from Docker's own apt repo (system daemon; adds $DOCKER_GROUP_USER to the docker group, which is root-equivalent)?" n && DO_DOCKER=1
  fi
fi

if want nvctk; then
  if have_nvctk; then
    if (( ! FORCE_NVCTK )) && pkg_upgradable nvidia-container-toolkit; then
      if ask_yn "the NVIDIA Container Toolkit $(pkg_installed_ver nvidia-container-toolkit) is installed; $(pkg_candidate_ver nvidia-container-toolkit) is available -- update it?" n; then
        FORCE_NVCTK=1; DO_NVCTK=1
      fi
    elif (( ! FORCE_NVCTK )); then
      skip "NVIDIA Container Toolkit $(pkg_installed_ver nvidia-container-toolkit) is installed and current"
    fi
    DO_NVCTK=1
  elif (( ! DO_NVCTK )) && (( DO_DOCKER )); then
    ask_yn "install the NVIDIA Container Toolkit so containers can use the GPUs?" y && { DO_NVCTK=1; DO_DOCKER=1; }
  fi
fi

# Asked only when there will be a docker to be rootless ABOUT, and only when a
# terminal is there to answer: an unattended run leaves the list empty and the
# step skips. Free text rather than yes/no because the answer is a set of
# accounts, and naming them is the whole decision -- rootless is per-account and
# granting it to one account grants nothing to the next.
DO_REVOKE_DOCKER=0
NEED_RELOGIN=""
ROOTLESS_READY=""
if want rootless && (( ! ROOTLESS_EXPLICIT )) && [[ -z "$ROOTLESS_ACCOUNTS" ]] \
   && { (( DO_DOCKER )) || have_docker; } && [[ -t 0 ]]; then
  _cands=""
  while IFS=: read -r _u _x _uid _g _c _home _s; do
    (( _uid >= 1000 && _uid < 65534 )) && [[ "$_home" == /home/* ]] && _cands="$_cands $_u"
  done < <(getent passwd)
  printf '\n'
  log "rootless docker lets an account run containers WITHOUT the docker group,"
  printf '      which is root-equivalent. This installs the root-only half:\n'
  printf '      subuid/subgid ranges, linger, and removal from the docker group.\n'
  printf '      The account itself then runs: provision-ubuntu-account.sh --docker-rootless\n'
  read -r -p "accounts to prepare for rootless docker (space-separated, empty for none)${_cands:+ [candidates:$_cands]}: " _reply || true
  ROOTLESS_ACCOUNTS="${_reply:-}"
  for _a in $ROOTLESS_ACCOUNTS; do
    [[ "$_a" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid account name '$_a'"
    getent passwd "$_a" >/dev/null || die "no such account: $_a (create it: sudo adduser $_a)"
  done
fi

# The revocation is the security-relevant half, so it is asked, not assumed --
# but it defaults to YES, because leaving the account in the group makes the
# rest of this step pointless and the account's own setup tool will refuse to
# run anyway.
if want rootless && [[ -n "$ROOTLESS_ACCOUNTS" ]]; then
  _in_group=""
  for _a in $ROOTLESS_ACCOUNTS; do
    in_docker_group "$_a" && _in_group="$_in_group $_a"
  done
  # Adding an account to the docker group and revoking it in the same run is a
  # contradiction, not a preference -- and the docker step runs first, so the
  # account would end up rootless AND root-equivalent.
  for _a in $ROOTLESS_ACCOUNTS; do
    want docker && (( DO_DOCKER )) && [[ "$_a" == "$DOCKER_GROUP_USER" ]] \
      && die "$_a is named as both DOCKER_GROUP_USER (added to the root-equivalent
   docker group) and a rootless account (which exists to keep it out of that
   group). Pick one, in the CONFIGURATION block:
     DOCKER_GROUP_USER   a human admin
     rootless            an agent, or any untrusted worker"
  done
  if [[ -n "$_in_group" ]]; then
    warn "in the docker group, which is ROOT-EQUIVALENT --$_in_group"
    warn "  a member runs:  docker run -v /:/host -it ubuntu chroot /host"
    warn "  and reads /etc/shadow, every ssh key and every stored credential."
    ask_yn "remove$_in_group from the docker group?" y && DO_REVOKE_DOCKER=1
  fi
fi

if want gpustate; then
  if have_gpustate; then
    if (( ! FORCE_GPUSTATE )); then
      printf '\n'
      list_replace "/etc/systemd/system/$GPU_STATE_UNIT.service"
      ask_yn "the $GPU_STATE_UNIT unit is installed -- replace it?" n && FORCE_GPUSTATE=1
    fi
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

# -------------------------------------------------------------- 1. hostname --

if want hostname; then
  _cur="$(hostname)"
  if [[ "$SYSTEM_HOSTNAME" == "$_cur" ]]; then
    skip "hostname is already $_cur"
  else
    log "setting hostname: $_cur -> $SYSTEM_HOSTNAME"
    run $SUDO hostnamectl set-hostname "$SYSTEM_HOSTNAME"
    # hostnamectl alone leaves /etc/hosts stale, and then every sudo call
    # prints "unable to resolve host <old>" until the next reboot.
    if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
      run $SUDO sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$SYSTEM_HOSTNAME/" /etc/hosts
    else
      (( CHECK_ONLY )) && printf '    \033[2m[would append]\033[0m 127.0.1.1 %s to /etc/hosts\n' "$SYSTEM_HOSTNAME" \
        || printf '127.0.1.1\t%s\n' "$SYSTEM_HOSTNAME" | $SUDO tee -a /etc/hosts >/dev/null
    fi
    HOSTNAME_CHANGED=1
  fi
fi

# --------------------------------------------------------------- 2. limits --

if want limits && [[ -n "$MEMLOCK_ACCOUNTS" ]]; then
  _lim="$TMPD/limits-memlock.conf"
  cp "$TEMPLATES/limits-memlock.conf" "$_lim"
  for _a in $MEMLOCK_ACCOUNTS; do
    getent passwd "$_a" >/dev/null || die "no such account: $_a"
    printf '%s soft memlock unlimited\n%s hard memlock unlimited\n' "$_a" "$_a" >>"$_lim"
  done
  if cmp -s "$_lim" /etc/security/limits.d/90-memlock.conf; then
    skip "memlock limits already current for: $MEMLOCK_ACCOUNTS"
  else
    list_replace /etc/security/limits.d/90-memlock.conf
    backup /etc/security/limits.d/90-memlock.conf
    log "raising memlock for: $MEMLOCK_ACCOUNTS (applies at their next login)"
    run $SUDO install -D -m 0644 -o root -g root "$_lim" /etc/security/limits.d/90-memlock.conf
  fi
elif want limits; then
  skip "MEMLOCK_ACCOUNTS is empty; not touching /etc/security/limits.d"
fi

# ------------------------------------------------------------------- 3. lvm --

if want lvm; then
  if (( ! LVM_OK )); then
    skip "$LVM_WHY"
  elif (( ! DO_GROW_LV )); then
    skip "leaving $LVM_PATH at its current size"
  else
    # Let LVM do the arithmetic with the same %FREE expression that was shown.
    log "growing $LVM_PATH by $(hb "$LVM_ADD_B"), leaving $(hb "$GROW_RESERVE_B") unallocated"
    run $SUDO lvextend -L "+${LVM_ADD_B}b" "$LVM_PATH"
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
    # A deliberate driver change means unholding first. Remember that we did,
    # so the holds are restored below -- otherwise this path silently leaves the
    # box in exactly the state the hold exists to prevent.
    #
    # Gated on the change being DELIBERATE: either you asked to reinstall/update
    # (you typed a branch, or said yes to a point release), or the driver you
    # asked for is genuinely not installed (a fresh box, or NVIDIA_DRIVER_PKG
    # naming a different branch). Merely reaching this step must never unhold --
    # that turns any routine run into an unattended driver upgrade.
    if { (( FORCE_NVIDIA )) || ! have_pkg "$NVIDIA_DRIVER_PKG"; } \
       && apt-mark showhold 2>/dev/null | grep -qE '^(nvidia-|libnvidia-)'; then
      log "unholding nvidia packages for a deliberate change"
      run $SUDO apt-mark unhold $(apt-mark showhold | grep -E '^(nvidia-|libnvidia-)')
      WAS_HELD=1
    fi
    # apt_install only installs what is MISSING, so it cannot upgrade. A
    # deliberate reinstall/update has to say so explicitly.
    if (( FORCE_NVIDIA )) && have_pkg "$NVIDIA_DRIVER_PKG"; then
      apt_upgrade_pkgs "$NVIDIA_DRIVER_PKG" "${NVIDIA_EXTRA_PKGS[@]}"
    else
      apt_install "$NVIDIA_DRIVER_PKG" "${NVIDIA_EXTRA_PKGS[@]}"
    fi
    if (( ! CHECK_ONLY )) && ! nvidia_dkms_ok; then
      warn "dkms has NOT built the nvidia module for $(uname -r)."
      warn "Check before rebooting:  dkms status; cat /var/lib/dkms/nvidia/*/build/make.log"
    fi
  fi

  if (( DO_HOLD_NVIDIA )) || [[ -n "${WAS_HELD:-}" ]]; then
    # The metapackage's deps are unversioned, so holding it alone still lets
    # libnvidia-* move underneath and desync from the loaded module.
    # Only packages version-tied to the driver branch. nvidia-prime,
    # nvidia-settings and libnvidia-egl-wayland1 are independent Ubuntu
    # packages -- holding them blocks their security updates for no benefit.
    mapfile -t _held < <(dpkg -l | awk '/^ii +(nvidia-|libnvidia-)/{print $2}' \
                         | grep -vE '^(nvidia-prime|nvidia-settings|libnvidia-egl-wayland1)')
    if (( ${#_held[@]} )); then
      log "holding ${#_held[@]} nvidia packages against apt upgrade"
      run $SUDO apt-mark hold "${_held[@]}"
    fi
  elif [[ -n "$(apt-mark showhold 2>/dev/null | grep '^nvidia-' || true)" ]]; then
    skip "nvidia packages already held ($(apt-mark showhold | grep -c -E '^(nvidia-|libnvidia-)') packages)"
  fi
fi

# ----------------------------------------------------------------- 7. docker --

if want docker && (( DO_DOCKER )); then
  add_apt_repo docker \
    "https://download.docker.com/linux/ubuntu/gpg" \
    "deb [arch=${ARCH} signed-by=@KEYRING@] https://download.docker.com/linux/ubuntu ${CODENAME} stable"
  if (( FORCE_DOCKER )); then
    apt_upgrade_pkgs "${DOCKER_PACKAGES[@]}"
  else
    apt_install "${DOCKER_PACKAGES[@]}"
  fi

  # Refuse to plant a root-owned image store inside somebody's home directory:
  # `deluser --remove-home` would then take every image with it.
  if [[ -n "$DOCKER_DATA_ROOT" ]]; then
    [[ "$DOCKER_DATA_ROOT" == /* ]] || die "DOCKER_DATA_ROOT must be an absolute path"
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
  _current_root="$($SUDO docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"

  # ADOPT an existing non-default data-root when none was requested. Otherwise a
  # plain run on a box already configured with one would write a daemon.json
  # without it, restart docker, and silently relocate storage to
  # /var/lib/docker -- orphaning every image. Never change what was not asked
  # to be changed.
  if [[ -z "$DOCKER_DATA_ROOT" && -n "$_current_root" && "$_current_root" != "/var/lib/docker" ]]; then
    warn "docker already uses data-root=$_current_root; keeping it."
    warn "set DOCKER_DATA_ROOT to change it deliberately."
    DOCKER_DATA_ROOT="$_current_root"
  fi
  if [[ -n "$DOCKER_DATA_ROOT" && -n "$_current_root" \
        && "$_current_root" != "$DOCKER_DATA_ROOT" \
        && -n "$($SUDO docker image ls -q 2>/dev/null)" ]]; then
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
      printf '  "log-driver": "json-file",\n'
      printf '  "log-opts": { "max-size": "100m", "max-file": "5" },\n'
      printf '  "default-shm-size": "%s",\n' "$DOCKER_SHM_SIZE"
      printf '  "default-ulimits": {\n    "memlock": { "Name": "memlock", "Hard": -1, "Soft": -1 }\n  }'
      [[ -n "$DOCKER_DATA_ROOT" ]] && printf ',\n  "data-root": "%s"' "$DOCKER_DATA_ROOT"
      printf '\n}\n'
    } >"$_dj"

    if cmp -s "$_dj" /etc/docker/daemon.json; then
      skip "/etc/docker/daemon.json already current"
    else
      list_replace /etc/docker/daemon.json
      backup /etc/docker/daemon.json
      run $SUDO install -D -m 0644 -o root -g root "$_dj" /etc/docker/daemon.json
      DOCKER_NEEDS_RESTART=1
    fi
  fi

  run $SUDO systemctl enable --now docker

  if [[ -n "${DOCKER_NEEDS_RESTART:-}" ]]; then
    if [[ -n "$($SUDO docker ps -q 2>/dev/null)" ]]; then
      warn "daemon.json changed but containers are running -- not restarting docker."
      warn "Restart it yourself when convenient:  sudo systemctl restart docker"
    else
      log "restarting docker to pick up daemon.json"
      run $SUDO systemctl restart docker
    fi
  fi

  if in_docker_group "$DOCKER_GROUP_USER"; then
    skip "$DOCKER_GROUP_USER is already in the docker group"
  else
    log "adding $DOCKER_GROUP_USER to the docker group (root-equivalent access)"
    run $SUDO usermod -aG docker "$DOCKER_GROUP_USER"
    NEED_NEWGRP=1
  fi
fi

# ------------------------------------------------------------------ 8. nvctk --

if want nvctk && (( DO_NVCTK )); then
  have_docker || (( CHECK_ONLY )) || die "the container toolkit needs docker; answer yes to the docker question"
  # NOTE the single quotes: $(ARCH) is apt's OWN substitution, evaluated when
  # apt reads the file. Let bash expand it and you get an empty path and a 404.
  add_apt_repo nvidia-container-toolkit \
    "https://nvidia.github.io/libnvidia-container/gpgkey" \
    'deb [signed-by=@KEYRING@] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /'
  if (( FORCE_NVCTK )); then
    apt_upgrade_pkgs "${NVCTK_PACKAGES[@]}"
  else
    apt_install "${NVCTK_PACKAGES[@]}"
  fi

  # Packages install fine without a driver; only the verification needs one.
  if gpu_ready; then
    if (( CHECK_ONLY )); then
      skip "would verify: nvidia-container-cli info"
    elif $SUDO nvidia-container-cli info >/dev/null 2>&1; then
      log "nvidia-container-cli sees the GPUs"
    else
      warn "nvidia-container-cli cannot see the GPUs; containers will not get them"
    fi
  else
    defer "verify the container runtime sees the GPUs (nvidia-container-cli info)"
  fi
fi

# --------------------------------------------------------------- 9. rootless --

# The root-only half of rootless docker, so that provision-ubuntu-account.sh can
# stay sudo-free. Runs AFTER the docker step, which is what installs
# docker-ce-rootless-extras. Nothing here starts a daemon: the daemon belongs to
# the account and is created by the account's own run.
if want rootless && [[ -n "$ROOTLESS_ACCOUNTS" ]]; then
  # Both come from earlier steps -- uidmap from packages, rootless-extras from
  # docker -- so a gap here means one of those was skipped, not that the list is
  # wrong. Say which, rather than letting the account discover it later.
  _rl_missing=()
  have_pkg uidmap || _rl_missing+=(uidmap)
  have_pkg docker-ce-rootless-extras || _rl_missing+=(docker-ce-rootless-extras)
  if (( ${#_rl_missing[@]} )); then
    warn "rootless needs ${_rl_missing[*]}, which this run has not installed."
    warn "  uidmap comes from the packages step, docker-ce-rootless-extras from"
    warn "  the docker step. Re-run including them:"
    warn "      ./provision-ubuntu-server.sh    # and say yes to docker"
  fi

  for _a in $ROOTLESS_ACCOUNTS; do
    log "rootless prerequisites for $_a"

    # 1. A subordinate uid/gid range, or there are no uids to map into the
    #    account's user namespace and the daemon cannot start at all.
    for _kind in uid gid; do
      _f="/etc/sub$_kind"
      if has_subid "$_a" "$_f"; then
        skip "  $_f range already present"
      else
        _start="$(next_subid "$_f")"
        _range="$_start-$(( _start + SUBID_COUNT - 1 ))"
        log "  adding $_f range $_range"
        if [[ "$_kind" == uid ]]; then
          run $SUDO usermod --add-subuids "$_range" "$_a"
        else
          run $SUDO usermod --add-subgids "$_range" "$_a"
        fi
      fi
    done

    # 2. Linger, or systemd tears the user manager down with the last session --
    #    taking the account's docker daemon and every container with it. For an
    #    agent account that is every logout, i.e. constantly.
    if [[ "$(loginctl show-user "$_a" -p Linger --value 2>/dev/null)" == yes ]]; then
      skip "  linger already enabled"
    else
      log "  enabling linger (its daemon outlives its sessions)"
      run $SUDO loginctl enable-linger "$_a"
    fi

    # 3. The docker group, which must NOT be held. Asked about up front; when
    #    declined, say plainly that the account's own run will fail, because
    #    dockerd-rootless-setuptool.sh aborts while /var/run/docker.sock is
    #    writable.
    if ! in_docker_group "$_a"; then
      skip "  not in the docker group"
    elif (( DO_REVOKE_DOCKER )); then
      log "  removing $_a from the docker group (root-equivalent)"
      run $SUDO gpasswd -d "$_a" docker
      NEED_RELOGIN="$NEED_RELOGIN $_a"
    else
      warn "  $_a keeps the ROOT-EQUIVALENT docker group, so rootless setup will"
      warn "  refuse to run for it. Undo later with:  sudo gpasswd -d $_a docker"
    fi
  done
  ROOTLESS_READY="$ROOTLESS_ACCOUNTS"
elif want rootless; then
  skip "no --rootless-accounts given; no per-account rootless prerequisites to install"
fi

# --------------------------------------------------------------- 10. gpustate --

if want gpustate && [[ -z "${SKIP_GPUSTATE:-}" ]]; then
  _cap_line=""
  [[ -n "$GPU_POWER_CAP" ]] && _cap_line="ExecStart=/usr/bin/nvidia-smi -pl $GPU_POWER_CAP"
  _unit="$TMPD/$GPU_STATE_UNIT.service"
  sed "s|__CAP_LINE__|$_cap_line|" "$TEMPLATES/gpu-state.service" >"$_unit"

  if cmp -s "$_unit" "/etc/systemd/system/$GPU_STATE_UNIT.service" && (( ! FORCE_GPUSTATE )); then
    skip "$GPU_STATE_UNIT.service already current"
  else
    list_replace "/etc/systemd/system/$GPU_STATE_UNIT.service"
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
  # Docker 29 routes --gpus through CDI and treats it as vendor-agnostic, so
  # `--gpus all` fails with "AMD CDI spec not found". The explicit CDI device
  # form works on every version that has a spec, so print that instead.
  have_nvctk && log "test the GPUs: docker run --rm --device nvidia.com/gpu=all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi"
  have_nvctk && warn "note: '--gpus all' fails on docker 29.x -- use --device nvidia.com/gpu=all"
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

  # State the pin explicitly, every run. The whole point of holding the driver is
  # that it does not move by surprise -- which is only reassuring if you can see
  # that it is still held, and know the one way to move it on purpose.
  _held_n="$(apt-mark showhold 2>/dev/null | grep -cE '^(nvidia-|libnvidia-)' || true)"
  if (( _held_n )); then
    log "driver: $NVIDIA_DRIVER_PKG $(nvidia_pkg_version) is PINNED -- $_held_n packages held."
    log "  apt, unattended-upgrades and a re-run of this script cannot move it."
    log "  It changes only if you ask, by one of:"
    echo "    ./provision-ubuntu-server.sh --only nvidia --reinstall    # newer point release"
    echo "    NVIDIA_DRIVER_PKG=nvidia-driver-610-open ./provision-ubuntu-server.sh --only nvidia"
    echo "    (a driver change needs a reboot before the new module loads)"
  else
    warn "the nvidia packages are NOT held -- an unattended-upgrades run can move"
    warn "libnvidia-* under the loaded module and detach the GPUs from running"
    warn "containers. Fix:  ./provision-ubuntu-server.sh --only nvidia"
  fi
fi

if [[ -n "$ROOTLESS_READY" ]]; then
  echo
  log "rootless docker prerequisites installed for:$ROOTLESS_READY"
  log "the rest is per-account and needs NO root. As each account:"
  echo "    ./provision-ubuntu-account.sh --docker-rootless"
  log "which installs its own daemon, its own daemon.json (a rootless daemon"
  log "reads nothing from /etc/docker) and its own nvidia no-cgroups config."
  [[ -n "$NEED_RELOGIN" ]] && \
    warn "removed from the docker group:$NEED_RELOGIN -- each must log out and back"
  [[ -n "$NEED_RELOGIN" ]] && \
    warn "in before that takes effect (groups are fixed at login)."
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
