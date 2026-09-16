# AMD RX 470/480/570/580/590 — Black Screen on Boot (HDMI has no EDID)

**Symptom:** monitor powers on but the screen stays black on a normal boot. Only typing `nomodeset` gives a picture — but then video acceleration is dead (llvmpipe, no Vulkan).

**Cause:** your monitor doesn't send a valid **EDID** (the data block the GPU reads to learn the panel's resolution). amdgpu then reports the HDMI port as **disconnected**, so Xorg/Wayland find "no connected screen" → black screen.

`nomodeset` "works" because it skips KMS and reuses the firmware framebuffer — at the cost of acceleration.

**Fix:** force a known EDID onto the HDMI port with kernel parameters. No extra firmware file needed — the kernel has `1920x1080.bin` built in.

Verified on Arch/CachyOS and Fedora, Linux 7.x, Gigabyte RX 590 (Polaris10, `1002:67df`).

---

## Setup — one command, any distro

```bash
git clone https://github.com/deopr/Polaris-edid-fix.patches.git
cd Polaris-edid-fix.patches
sudo bash setup.sh
```

`setup.sh` is bootloader-aware. It locates your boot config, appends the two
kernel parameters (only once — re-runs are safe), writes the module options
file, and rebuilds initramfs/UKIs with your distro's tool.

| Bootloader / mechanism | Config it updates | Initramfs tool used |
|---|---|---|
| GRUB (Debian/Ubuntu/openSUSE/…) | `/etc/default/grub` + `update-grub` / `grub(2)-mkconfig` | `update-initramfs` |
| GRUB2 (Fedora/RHEL, …) | `grubby --update-kernel=ALL` | `dracut` |
| systemd-boot | `/boot/loader/entries/*.conf` (appends to `options`) | `dracut` / `mkinitcpio` / `update-initramfs` |
| Limine | `/boot/limine.conf` / `/boot/EFI/BOOT/limine.conf` | `mkinitcpio` / `dracut` |
| rEFInd | `/boot/refind_linux.conf` | any |
| UKI kernel-cmdline (Arch/Fedora UKI) | `/etc/kernel/cmdline` | `mkinitcpio` / `dracut` |

What gets applied everywhere:

```
/etc/modprobe.d/99-amdgpu-modeset.conf   # safety net, survives param loss
```

The two parameters injected:

```
amdgpu.modeset=1   drm.edid_firmware=HDMI-A-0:edid/1920x1080.bin
```

---

## Manual setup (if the script can't detect your setup)

Add the parameters to your kernel cmdline and rebuild initramfs:

- **GRUB (Debian/Ubuntu):** edit `/etc/default/grub`, add to `GRUB_CMDLINE_LINUX_DEFAULT`, run `sudo update-grub`
- **GRUB2 (Fedora/RHEL):** `sudo grubby --update-kernel=ALL --args="amdgpu.modeset=1 drm.edid_firmware=HDMI-A-0:edid/1920x1080.bin"`
- **Arch (systemd-boot):** append to `options ...` in `/boot/loader/entries/*.conf`
- **Arch/Limine (UKI):** edit `/etc/kernel/cmdline`, then `sudo mkinitcpio -P`
- **openSUSE:** edit `/etc/default/grub` → `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`

Then run the matching initramfs rebuild if you didn't already: `sudo update-initramfs -u`, `sudo dracut --force`, or `sudo mkinitcpio -P`.

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
  for c in /sys/class/drm/card*/card*-HDMI-A-*/status; do echo "$c = $(cat "$c")"; done
  ```
  Use whichever shows as `disconnected` — and edit it in the top of `setup.sh` (`PARAMS=`) if it isn't `HDMI-A-0`.

- **Other resolutions:** the standard 1080p EDID is used automatically. For other modes, drop your own file into `/lib/firmware/edid/<name>.bin` and reference `edid/<name>.bin`.

- **Distro coverage:** the script detects the bootloader and initramfs tool at runtime, so it's distro-agnostic by design — not a package per distro. Build from source on any distro: Debian/Ubuntu/Fedora/Arch/openSUSE/Void/Alpine/Gentoo all work.

## When NOT to use this fix

**RESOLVED / oopsie:** the override works only when your monitor's EDID is
*genuinely* broken/missing. In my case the `/lib/firmware/edid/1920x1080.bin`
file was a **corrupt dump**, so the kernel served garbage *instead of* a
healthy panel EDID → wrong reduced-blanking modes (59.93 Hz) and tearing.

**Fix (both cases):**
- Monitor EDID **actually broken** → keep this override, but use a **valid**
  blob (kernel reference `edid/1920x1080.bin`), never a dump of a broken one.
- Monitor EDID **fine / file was garbage** → remove `drm.edid_firmware` and
  `video=...` params entirely and reboot.

**Warning:** the kernel's `1920x1080.bin` is **native 60 Hz only** — for
120/144/180 Hz panels, build `edid/<name>.bin` from your monitor's real native
timing instead, or you'll get capped at 60 Hz.

## License

MIT — use, fork, modify freely.
