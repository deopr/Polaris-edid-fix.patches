#!/usr/bin/env bash
#
# setup.sh — Apply the "no-EDID black screen" fix for AMD Polaris GPUs
#            (RX 470/480/570/580/590) on ANY Linux distribution.
#
# Symptom:  monitor powers on but stays black on normal boot. Only typing
#           `nomodeset` gives a picture — and that kills video acceleration
#           (llvmpipe, no Vulkan).
# Cause:    the monitor sends no/blank EDID over HDMI, so amdgpu marks the
#           connector as "disconnected" and the session finds no screen.
# Fix:      force the kernel built-in 1080p EDID onto the HDMI connector and
#           keep amdgpu modesetting on — using kernel cmdline parameters plus
#           the amdgpu module options file.
#
# The script is bootloader/distro aware. It detects and updates:
#   • GRUB (Debian/Ubuntu/openSUSE/…)     /etc/default/grub + update-grub
#                                        / grub2-mkconfig / grub-mkconfig
#   • GRUB2 (Fedora/RHEL)                 grubby --update-kernel=ALL
#   • systemd-boot                        /boot/loader/entries/*.conf
#   • Limine                              /boot/limine.conf, /boot/EFI/BOOT/limine.conf
#   • rEFInd                              /boot/refind_linux.conf
#   • UKI kernel-cmdline (Arch/Fedora)    /etc/kernel/cmdline
#
# initramfs is rebuilt with whatever the distro provides:
#   mkinitcpio | dracut | update-initramfs
#
# Safe to re-run: params are only added once, and every modified file is
# backed up to <file>.bak.<timestamp>.

set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"

# Kernel parameters that fix the black screen.
PARAMS="amdgpu.modeset=1 drm.edid_firmware=HDMI-A-0:edid/1920x1080.bin"

# Module options file — universal, works on every distro.
MODPROBE_CONF="/etc/modprobe.d/99-amdgpu-modeset.conf"
MODPROBE_BODY="\
# amdgpu black-screen fix (no EDID on HDMI)
options drm edid_firmware=HDMI-A-0:edid/1920x1080.bin
options amdgpu modeset=1
"

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root:  sudo bash $0"

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    cp -a "$f" "$f.bak.$TS"
    info "backup: $f -> $f.bak.$TS"
}

# --------------------------------------------------------------------------
# 1. Module options file (needed even if the cmdline param is lost)
# --------------------------------------------------------------------------
write_modprobe_conf() {
    if [[ -f "$MODPROBE_CONF" ]] && grep -q 'edid_firmware=' "$MODPROBE_CONF"; then
        info "$MODPROBE_CONF already configured — skipping"
        return 0
    fi
    backup "$MODPROBE_CONF"
    printf '%s' "$MODPROBE_BODY" > "$MODPROBE_CONF"
    ok "wrote $MODPROBE_CONF"
}

# --------------------------------------------------------------------------
# 2. Kernel cmdline management — one mechanism wins, in order of preference
# --------------------------------------------------------------------------
# Append PARAMS to the end of a plain text options file.
append_to_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    if grep -q 'drm.edid_firmware=' "$f"; then
        info "$f already configured — skipping"
        return 0
    fi
    backup "$f"
    printf ' %s\n' "$PARAMS" >> "$f"
    ok "appended kernel params to $f"
}

# Fedora / RHEL / any distro with grubby (live GRUB2 management).
try_grubby() {
    command -v grubby >/dev/null || return 1
    if grubby --info=ALL 2>/dev/null | grep -q 'drm.edid_firmware='; then
        info "grubby kernels already configured — skipping"
        return 0
    fi
    grubby --update-kernel=ALL --args="$PARAMS"
    ok "grubby: applied params to all kernel entries"
}

# Debian/Ubuntu/openSUSE-style /etc/default/grub.
try_grub_default() {
    local fgrub=/etc/default/grub
    [[ -f "$fgrub" ]] || return 1
    if grep -q 'drm.edid_firmware=' "$fgrub"; then
        info "$fgrub already configured — skipping"
    else
        backup "$fgrub"
        if grep -q '^GRUB_CMDLINE_LINUX=' "$fgrub"; then
            sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"$PARAMS |" "$fgrub"
        else
            printf 'GRUB_CMDLINE_LINUX="%s"\n' "$PARAMS" >> "$fgrub"
        fi
        ok "updated $fgrub"
    fi
    if command -v update-grub >/dev/null; then
        update-grub
        ok "regenerated boot config (update-grub)"
    elif command -v grub2-mkconfig >/dev/null; then
        local out
        out="$(ls /boot/grub2/grub.cfg /boot/grub/grub.cfg 2>/dev/null | head -1)"
        [[ -n "$out" ]] && grub2-mkconfig -o "$out" && ok "regenerated boot config (grub2-mkconfig)"
    elif command -v grub-mkconfig >/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg && ok "regenerated boot config (grub-mkconfig)"
    fi
    return 0
}

# systemd-boot: append to `options` in every loader entry.
try_systemd_boot() {
    local found=0 e
    for e in /boot/loader/entries/*.conf; do
        [[ -f "$e" ]] || continue
        found=1
        if grep -q 'drm.edid_firmware=' "$e"; then
            info "$e already configured — skipping"
        else
            backup "$e"
            sed -i "/^[[:space:]]*options[[:space:]]/ s|\$| $PARAMS|" "$e"
            ok "systemd-boot: updated $e"
        fi
    done
    return $(( 1 - found ))
}

# Limine: append to every `cmdline:` line.
try_limine() {
    local f
    for f in /boot/limine.conf /boot/EFI/BOOT/limine.conf; do
        [[ -f "$f" ]] || continue
        if grep -q 'drm.edid_firmware=' "$f"; then
            info "$f already configured — skipping"
        else
            backup "$f"
            sed -i "/^cmdline:/ s|.*|& $PARAMS|" "$f"
            ok "limine: updated $f ($(grep -c '^cmdline:' "$f") boot entries)"
        fi
        return 0
    done
    return 1
}

# rEFInd: append to the trailing quote of every boot option line.
try_refind() {
    local f=/boot/refind_linux.conf
    [[ -f "$f" ]] || return 1
    if grep -q 'drm.edid_firmware=' "$f"; then
        info "$f already configured — skipping"
    else
        backup "$f"
        sed -i "s|\"$| $PARAMS\"|" "$f"
        ok "rEFInd: updated $f"
    fi
    return 0
}

# UKI / mkinitcpio-dracut style plain cmdline source file.
try_kernel_cmdline() {
    append_to_file /etc/kernel/cmdline
}

# --------------------------------------------------------------------------
# 3. Rebuild initramfs / UKIs with whatever the distro ships
# --------------------------------------------------------------------------
rebuild_initramfs() {
    if command -v mkinitcpio >/dev/null; then
        mkinitcpio -P
        ok "initramfs rebuilt (mkinitcpio)"
    elif command -v dracut >/dev/null; then
        dracut --force
        ok "initramfs rebuilt (dracut)"
    elif command -v update-initramfs >/dev/null; then
        update-initramfs -u
        ok "initramfs rebuilt (update-initramfs)"
    else
        warn "no initramfs tool found (mkinitcpio/dracut/update-initramfs) — rebuild it manually"
    fi
}

# --------------------------------------------------------------------------
# 4. Main
# --------------------------------------------------------------------------
show_connectors() {
    local found=0 c
    for c in /sys/class/drm/card*/card*-HDMI-A-*/status; do
        [[ -e "$c" ]] || continue
        found=1
        echo "  $c = $(cat "$c")"
    done
    if [[ $found -eq 1 ]]; then
        echo "  >> If the disconnected connector is not HDMI-A-0, edit PARAMS at the top of this script."
    else
        echo "  (no HDMI-A connectors found in /sys/class/drm — check your cable/port)"
    fi
}

main() {
    local updated=0

    echo ""
    echo "  AMD Polaris EDID black-screen fix"
    echo "  --------------------------------"
    echo ""

    write_modprobe_conf && updated=$((updated + 1)) || true
    try_grubby         && updated=$((updated + 1)) || true
    try_grub_default   && updated=$((updated + 1)) || true
    try_systemd_boot   && updated=$((updated + 1)) || true
    try_limine         && updated=$((updated + 1)) || true
    try_refind         && updated=$((updated + 1)) || true
    [[ -f /etc/kernel/cmdline ]] && try_kernel_cmdline && updated=$((updated + 1)) || true

    # if nothing matched, fall back to a clear manual hint
    if ! grep -qr 'drm.edid_firmware=' \
        /etc/default/grub /boot/loader/entries /boot/limine.conf \
        /boot/EFI/BOOT/limine.conf /boot/refind_linux.conf \
        /etc/kernel/cmdline /etc/modprobe.d/99-amdgpu-modeset.conf 2>/dev/null; then
        warn "no known bootloader config found."
        warn "Manually add the following to your kernel cmdline and rebuild initramfs:"
        echo "    $PARAMS"
    fi

    rebuild_initramfs

    echo ""
    echo "  HDMI connectors:"
    show_connectors
    echo ""
    echo "== Done. Reboot WITHOUT typing 'nomodeset' and pick your newest kernel. =="
    echo "   Verify afterwards:"
    echo "     readlink /sys/class/drm/card*/device/driver   # -> amdgpu"
    echo "     glxinfo -B                                    # OpenGL: radeonsi (NOT llvmpipe)"
    echo ""
    echo "   Updated $updated component(s)."
}

main "$@"