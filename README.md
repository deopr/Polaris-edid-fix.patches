# AMD RX 570/580/590 Black Screen on Boot — HDMI Has No EDID

**Symptom:** black screen (monitor powered on) on normal boot. Only typed `nomodeset` gives a picture, but then video acceleration is disabled (llvmpipe, no Vulkan).

**Cause:** your monitor doesn't send a valid **EDID** (the data block the GPU reads to know the panel's resolution). amdgpu then reports the HDMI port as **disconnected**, so Xorg/Wayland find "no connected screen" → black screen.

`nomodeset` "works" because it skips KMS and reuses the firmware framebuffer — at the cost of acceleration.

**Fix:** force a known EDID onto the HDMI port with one kernel parameter. No extra file needed — the kernel has `1920x1080.bin` built in.

Verified on Arch/CachyOS, Linux 7.x, Limine + UKI, Gigabyte RX 590 (Polaris10, `1002:67df`).

---

## Setup

Update the following to your own values:
- `<YOUR-PARTUUID>` → your root partition's PARTUUID (`blkid`).

### 1. Kernel cmdline (source for UKI)

```bash
sudo nano /etc/kernel/cmdline
```

Make it contain:

```
root=PARTUUID=<YOUR-PARTUUID> zswap.enabled=0 rw rootfstype=btrfs amdgpu.modeset=1 drm.edid_firmware=HDMI-A-0:edid/1920x1080.bin
```

### 2. Module options (safety net, in case the param is lost)

```bash
sudo tee /etc/modprobe.d/99-amdgpu-modeset.conf <<'EOF'
options drm edid_firmware=HDMI-A-0:edid/1920x1080.bin
options amdgpu modeset=1
EOF
```

### 3. Rebuild initramfs / UKIs so the cmdline is baked in

```bash
sudo mkinitcpio -P
```

### 4. (Limine) your boot entries should use the same cmdline

Edit `/boot/EFI/BOOT/limine.conf` to include `amdgpu.modeset=1 drm.edid_firmware=HDMI-A-0:edid/1920x1080.bin`.

### 5. Reboot — WITHOUT typing `nomodeset`

Pick your newest kernel. You should reach the login screen with hardware acceleration.

---

## Verify it worked

```bash
readlink /sys/class/drm/card*/device/driver     # → amdgpu
glxinfo -B                                       # OpenGL: radeonsi, real GPU (NOT llvmpipe)
vulkaninfo --summary                             # deviceName: RADV POLARIS10
```

---

## Notes

- **Connector name can differ** (`HDMI-A-0` vs `HDMI-A-1`). Check after a normal boot:
  ```bash
  for c in /sys/class/drm/card*/card*-HDMI-A-*/status; do echo "$c = $(cat $c)"; done
  ```
  Use whichever shows as `disconnected`. (In this test `HDMI-A-0` applied cleanly even though the port enumerates as `HDMI-A-1`.)

- **Other resolutions:** the standard 1080p EDID is used automatically. For other modes, drop your own file into `/lib/firmware/edid/<name>.bin` and reference `edid/<name>.bin`.
