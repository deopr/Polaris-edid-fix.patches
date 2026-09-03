#!/usr/bin/env bash
#
# apply-amdgpu-black-screen-fix.sh
# Applies fixes/ patches to enable hardware video acceleration on
# AMD RX 570/580/590 (Polaris) when the monitor provides no EDID over HDMI.
#
# Usage:
#   sudo bash apply-amdgpu-black-screen-fix.sh
#
# What it does, in order:
#   1. Applies fixes/0001-kernel-cmdline.patch                -> /etc/kernel/cmdline
#   2. Applies fixes/0002-limine-boot-entries.patch           -> /boot/EFI/BOOT/limine.conf
#   3. Applies fixes/0003-amdgpu-modprobe-modeset.conf.patch  -> /etc/modprobe.d/99-amdgpu-modeset.conf
#   4. Rebuilds initramfs/UKIs (mkinitcpio -P)
#
# Safe to re-run: already-applied patches are skipped, and every modified
# file is backed up to <file>.bak.<timestamp> before being changed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXES_DIR="$REPO_DIR/fixes"
TS="$(date +%Y%m%d-%H%M%S)"

PATCHES=(
  "0001-kernel-cmdline.patch"
  "0002-limine-boot-entries.patch"
  "0003-amdgpu-modprobe-modeset.conf.patch"
)

if [[ $EUID -ne 0 ]]; then
  echo "error: run as root:  sudo bash $0" >&2
  exit 1
fi

# Map patch -> the real target file (paths are a/ + b/ relative to /).
target_of() {
  local patch="$1"
  case "$patch" in
    0001*) echo "/etc/kernel/cmdline" ;;
    0002*) echo "/boot/EFI/BOOT/limine.conf" ;;
    0003*) echo "/etc/modprobe.d/99-amdgpu-modeset.conf" ;;
    *)     echo "" ;;
  esac
}

apply_patch() {
  local patch="$FIXES_DIR/$1" target
  target="$(target_of "$1")"
  [[ -n "$target" ]] || { echo "error: unknown patch $1" >&2; exit 1; }
  [[ -f "$patch" ]]  || { echo "error: missing $patch" >&2; exit 1; }

  # Skip if already applied (check against the real file).
  # patch -p1 dry-run reports "Reversed" / nothing when already present.
  if patch -p1 -N --dry-run < "$patch" 2>&1 | grep -qiE 'reversed|previously applied|ignored'; then
    echo "[skip] already applied: $1 -> $target"
    return 0
  fi

  # Backup the real file only if it changed / needs patching.
  mkdir -p "$(dirname "$target")"
  if [[ -f "$target" ]]; then
    echo "[backup] $target -> $target.bak.$TS"
    cp -a "$target" "$target.bak.$TS"
  fi

  echo "[apply] $1 -> $target"
  patch -p1 < "$patch"
  echo "[ok] patched: $target"
}

for p in "${PATCHES[@]}"; do
  apply_patch "$p"
done

echo ""
echo ">> Rebuilding initramfs / UKIs (mkinitcpio -P) ..."
mkinitcpio -P

echo ""
echo "== Done. Reboot WITHOUT typing 'nomodeset' and pick your newest kernel. =="
