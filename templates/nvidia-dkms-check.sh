#!/usr/bin/env bash
#
# nvidia-dkms-check -- verify dkms has built the nvidia module for every
# installed kernel, not just the running one.
#
# The failure this exists to catch: an unattended security kernel lands, dkms
# rebuilds the nvidia module for it, and the rebuild FAILS. Nothing surfaces
# that. The box keeps running perfectly on the old kernel with the old module
# still resident -- until the next reboot boots the new kernel, finds no module,
# and every GPU disappears. On a box serving models that is discovered at the
# worst possible moment, by the thing that stopped working.
#
# Exits non-zero when a kernel has no module, so the systemd unit that runs it
# goes `failed` and stays visible in `systemctl --failed`.

set -euo pipefail

# No nvidia dkms source means there is nothing to verify -- this is not an
# error, it is a box without the driver.
if ! dkms status -m nvidia >/dev/null 2>&1 || [[ -z "$(dkms status -m nvidia 2>/dev/null)" ]]; then
  echo "no nvidia dkms module registered; nothing to check"
  exit 0
fi

# Read the whole status once. NOT `dkms status | grep -q`: grep exits at the
# first match, dkms takes SIGPIPE writing the next line, and under `set -o
# pipefail` that reports failure on a perfectly healthy box.
STATUS="$(dkms status -m nvidia 2>/dev/null)"

built_for() {
  local kver="$1" line
  while IFS= read -r line; do
    if [[ "$line" == *", $kver, "*": installed" ]]; then return 0; fi
  done <<<"$STATUS"
  return 1
}

rc=0
found=0
# Every installed kernel, not just the running one: the whole point is the
# kernel you have not booted yet.
for img in /boot/vmlinuz-*; do
  [[ -e "$img" ]] || continue
  kver="${img##*/vmlinuz-}"
  found=1
  if built_for "$kver"; then
    echo "ok: nvidia module built for $kver"
  else
    echo "MISSING: no nvidia module for installed kernel $kver"
    rc=1
  fi
done

(( found )) || { echo "no kernels found under /boot; nothing to check"; exit 0; }

if (( rc )); then
  echo
  echo "Rebooting into a kernel with no nvidia module takes every GPU down."
  echo "Rebuild before rebooting:   dkms autoinstall"
  echo "Then confirm:               dkms status -m nvidia"
fi
exit "$rc"
