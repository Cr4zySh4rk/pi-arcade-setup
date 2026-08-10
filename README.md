# pi-arcade-setup

One script that turns a fresh **Raspberry Pi OS Lite (64-bit)** install into a dual-frontend arcade cabinet: **RetroPie** (MAME + a set of common emulator cores) with both classic **EmulationStation** and **ES-DE (EmulationStation Desktop Edition)** available as switchable frontends.

It's a faithful automation of a real, hand-documented build — DSI touchscreen rotation, a source-patched ES-DE with a custom "Restart EmulationStation" quit-menu option, three ES-DE themes, a custom in-frontend "RetroPie Setup" menu, boot splash video, a polkit fix so Reboot/Power Off actually work from a headless kiosk, and a controller-driven brightness/volume hotkey daemon with an in-frontend remapping tool.

The reference hardware is a Raspberry Pi 4 with a **Waveshare 10.1" DSI Touch A** display and a PS4-style **GP2040-CE** controller — the script's defaults match that build exactly. Every hardware-specific value is also a configuration variable, so it works on generic HDMI setups and other controllers too (see [Configuration](#configuration)).

This script has been verified directly against the reference Pi over SSH — every phase's output on disk (display config, ES-DE build + patch, themes, custom RetroPie menu, splash, polkit rule, controller hotkey mapping) was diffed against what `install.sh` actually generates, and a few real discrepancies found in that process were fixed in both places (see [Known limitations](#known-limitations)).

## Quick start

Flash Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager, set your username/password/Wi-Fi/SSH in the Imager's own customization options, boot the Pi, and SSH in as that user (**not** root). Then run:

```bash
curl -fsSL https://raw.githubusercontent.com/Cr4zySh4rk/pi-arcade-setup/main/install.sh | bash
```

Don't prefix this with `sudo` — the script calls `sudo` itself for the specific commands that need it, the same way the original hand-run build did.

**Before piping a script from the internet into `bash`, read it first.** That's good practice for any curl-into-bash installer, this one included: [install.sh](install.sh).

## What to expect

- Full run time is roughly **1.5–3 hours** on a Pi 4, most of it RetroPie's own `basic_install` and the ES-DE source build.
- The Pi **reboots itself** at a couple of points (after the base OS update, and after applying display settings if `ENABLE_DSI_DISPLAY=true`). Your SSH session will drop — that's expected. The installer sets up a one-shot `systemd` service that automatically resumes the setup after each reboot, so you don't need to log back in and re-run anything. It removes that service once the whole build is done.
- Progress and errors are logged to `/var/log/pi-arcade-setup.log` on the Pi. If you get disconnected, SSH back in and `tail -f /var/log/pi-arcade-setup.log` to watch progress.
- The script is **safe to re-run**. Every phase is tracked in `/opt/pi-arcade-setup/state`; completed phases are skipped, so if something fails partway (flaky network, a package mirror hiccup) you can just run the same one-liner again.
- By default it reboots into the finished arcade UI when everything is done (`AUTO_REBOOT_AT_END=true`).

## What it installs (phase by phase)

1. **Base OS update** — locale, optional timezone, `apt full-upgrade`, base packages. Reboots once for a clean baseline kernel.
2. **DSI display setup** *(if `ENABLE_DSI_DISPLAY=true`, the default)* — KMS overlay, kernel cmdline rotation, larger console font for the high-DPI panel. Reboots to activate it.
3. **RetroPie** — clones `RetroPie-Setup` and runs `basic_install` (RetroPie core, RetroArch, classic EmulationStation, standard emulator set).
4. **Emulators** — installs `lr-mame` (always) plus the cores listed in `EMULATOR_CORES` (SNES, PS1, PSP, NES, GB/GBC, Genesis, N64, etc. by default).
5. **RetroArch controller autoconfig** — populates RetroArch's *active* autoconfig directory with its full ~440-profile preset library (Xbox, PlayStation, 8BitDo, and hundreds more, matched by USB vendor/product id). Without this, a controller can work fine for menu navigation but do nothing inside actual games — RetroPie only auto-generates an autoconfig profile for a controller you've walked through classic EmulationStation's own input-configuration screen, and ES-DE doesn't do this at all. This closes that gap for any common controller up front.
6. **File sharing** — ProFTPD, for dropping ROMs onto the Pi over the network.
7. **Disk cleanup** — `apt autoremove`/`clean`.
8. **ES-DE**, built from source (no prebuilt ARM package exists) with `DEINIT_ON_LAUNCH` so it can run directly on the console without a desktop environment.
9. **ES-DE Quit-menu patch** — removes the unreliable "Suspend" option and adds "Restart EmulationStation", by patching ES-DE's C++ source before building it (matched against the real `stable-3.4` source; if a future ES-DE version changes that code, the patch is skipped with a warning rather than failing the whole build).
10. **ES-DE configuration** — first-run default settings, then points it at RetroPie's existing ROM folder and sets the theme/aspect ratio.
11. **Emulator reuse** — symlinks ES-DE to RetroPie's existing RetroArch/PPSSPP install and libretro cores, so nothing is set up twice.
12. **Themes** — clones three ES-DE themes (`artflix-revisited`, `art-book-next`, `alekfull-nx`) and installs the actual curated per-theme artwork (logos, backgrounds, metadata) for the custom RetroPie-menu system from [`theme-art/`](theme-art) in this repo — pulled directly from the reference build, not generated placeholders.
13. **Frontend autostart/switching** — `autostart.sh` boots into whichever frontend is selected, with the restart-loop and clean-shutdown log detection needed to make Quit/Reboot/Power Off/Restart all behave correctly; a `switch-frontend.sh [esde|classic]` helper and an `esde` relaunch command. Also enables console autologin and installs the `/etc/profile.d/10-retropie.sh` trigger (RetroPie's own optional "autostart" module, which `basic_install` does not enable by itself) so the Pi boots straight into the arcade UI instead of a login prompt.
14. **Custom "RetroPie Setup" system in ES-DE** — reproduces classic EmulationStation's built-in config-tools menu (Audio, Bluetooth, File Manager, Raspi-Config, RetroArch, Netplay, RetroPie-Setup, Run Command, Show IP, Splashscreen, WiFi) inside ES-DE, correctly wired through `openvt`+`TERM=linux` so the whiptail/curses tools actually render.
15. **Splash screen** — configures the existing RetroPie splash mechanism's rotation, and downloads a custom splash video from `SPLASH_VIDEO_URL` (defaults to the bundled [`splash/retro-splash.mp4`](splash/retro-splash.mp4) in this repo).
16. **Polkit fix** — grants your user passwordless authorization to reboot/power off/suspend, which headless kiosk setups need (`sudo`'s `NOPASSWD` alone isn't enough — this is a separate polkit-layer permission).
17. **Controller hotkey daemon** — holds L3+R3 while pressing Square/X/Triangle/Circle to adjust screen brightness and volume system-wide, regardless of what has input focus.
18. **In-frontend "Hotkey Config" tool** — a full-screen wizard (reachable from the RetroPie Setup menu inside ES-DE, or `sudo python3 ~/scripts/hotkey-remap.py`) to re-capture your controller's button numbers without SSH.

## Configuration

Everything is an environment variable with a sensible default, so `curl ... | bash` reproduces the reference build with no input needed. Override any of them by exporting the variable first, e.g.:

```bash
ENABLE_DSI_DISPLAY=false ENABLE_CONTROLLER_HOTKEYS=false \
  curl -fsSL https://raw.githubusercontent.com/Cr4zySh4rk/pi-arcade-setup/main/install.sh | bash
```

| Variable | Default | Purpose |
|---|---|---|
| `PI_USER` / `PI_HOME` | current user / `$HOME` | Account the arcade UI runs as. |
| `LOCALE` | `en_US.UTF-8` | System locale. |
| `TIMEZONE` | *(unset)* | e.g. `America/New_York`; left alone if empty. |
| `ENABLE_DSI_DISPLAY` | `true` | Turns on the Waveshare DSI overlay, kernel cmdline rotation, and console font tweak. Set `false` for a plain HDMI display. |
| `DSI_OVERLAY` | `vc4-kms-dsi-waveshare-panel-v2,10_1_inch_a` | `dtoverlay` value for your panel — swap for your vendor's overlay if it's a different DSI display. |
| `DSI_CMDLINE_ROTATE` | `video=DSI-1:800x1280e,rotate=90` | Kernel/KMS rotation. |
| `FBCON_ROTATE` | `3` | Linux text-console rotation (0–3, matches the KMS rotation). |
| `ESDE_SCREENROTATE` | `270` | ES-DE's own rotation flag, in **degrees**. |
| `CLASSIC_ES_SCREENROTATE` | `3` | Classic EmulationStation's rotation flag, an **SDL enum** (0–3) — not the same convention as ES-DE. |
| `CLASSIC_ES_SCREENSIZE` | `1280 800` | Classic ES `--screensize`. |
| `ESDE_THEME_ASPECT` | `16:10` | ES-DE `ThemeAspectRatio` setting. |
| `SPLASH_TRANSFORM_TYPE` | `90` | VLC `--transform-type` for the splash video (its own separate rotation convention). Only applied if `ENABLE_DSI_DISPLAY=true`. |
| `SPLASH_VIDEO_URL` | bundled [`splash/retro-splash.mp4`](splash/retro-splash.mp4) | URL of an `.mp4` to use as the boot splash. Set to an empty string to keep the stock RetroPie image splash instead. |
| `DO_RPI_FIRMWARE_UPDATE` | `false` | Runs `rpi-update`; only needed if your panel is blank on older firmware. |
| `EMULATOR_CORES` | `lr-snes9x,lr-pcsx-rearmed,ppsspp,lr-fceumm,lr-gambatte,lr-genesis-plus-gx,lr-nestopia,lr-picodrive,mupen64plus` | Comma-separated RetroPie-Setup package ids to install in addition to MAME. |
| `ESDE_BRANCH` | `stable-3.4` | ES-DE git branch/tag to build. |
| `APPLY_ESDE_QUITMENU_PATCH` | `true` | Apply the Restart-EmulationStation source patch. |
| `INSTALL_THEMES` | `true` | Clone the three ES-DE themes and install the bundled reference system art. |
| `ESDE_THEME_NAME` | `artflix-revisited` | Active ES-DE theme. |
| `INITIAL_FRONTEND` | `esde` | `esde` or `classic` — which frontend boots by default. |
| `ENABLE_CONSOLE_AUTOSTART` | `true` | Enables console autologin (`raspi-config nonint do_boot_behaviour B2`) and installs `/etc/profile.d/10-retropie.sh`, the actual tty1-login trigger for `autostart.sh`. This is RetroPie's own optional "autostart" module — `basic_install` alone does not wire it up, so without this the Pi boots to a login prompt instead of the arcade UI. |
| `ENABLE_CONTROLLER_HOTKEYS` | `true` | Installs the brightness/volume hotkey daemon. Safe on generic hardware — it no-ops gracefully with no controller/backlight, and is remappable later regardless. |
| `ALSA_CARD_INDEX` | `0` | ALSA card used for the hardware volume mixer. |
| `BTN_L3` / `BTN_R3` / `BTN_SQUARE` / `BTN_X` / `BTN_CIRCLE` / `BTN_TRIANGLE` | GP2040-CE mapping currently active on the reference build (`9`/`10`/`2`/`0`/`1`/`3`), captured live via the remap tool | Default joystick button numbers. Re-capture for your own controller with the in-frontend "Hotkey Config" tool after install — button numbering isn't standardized across controllers, and can shift even on the same controller across firmware/reconnects. |
| `HOTKEY_STEP` | `5` | Brightness/volume step size per press, in percent. |
| `AUTO_REBOOT_AT_END` | `true` | Reboot into the finished arcade UI once setup completes. |

## After install

- **Copy ROMs** into `~/RetroPie/roms/<system>/` (e.g. `arcade`, `snes`, `psx`, `psp`) over the network via FTP (ProFTPD, port 21, jailed to your home directory), then rescan from the frontend or reboot.
- **Switch frontends**: `~/switch-frontend.sh esde` or `~/switch-frontend.sh classic` (takes effect on next boot/restart).
- **Relaunch ES-DE** without rebooting after a deliberate Quit: run `esde`.
- **Remap controller hotkeys**: RetroPie Setup → *Hotkey Config* inside ES-DE, or `sudo python3 ~/scripts/hotkey-remap.py` over SSH.
- **Logs**: `/var/log/pi-arcade-setup.log` (installer), `~/ES-DE/logs/es_log.txt` (ES-DE), `/var/log/controller-hotkeys.log` (hotkey daemon).
- **Controller works in menus but not in-game?** This is almost always a missing RetroArch autoconfig profile, not a broken controller — the installer pre-populates ~440 common profiles (step 5 above), but a controller RetroArch has never seen the exact USB identity of won't have one. Confirm with `grep -i autoconf <(XDG_RUNTIME_DIR=/run/user/$(id -u) timeout 5 /opt/retropie/emulators/retroarch/bin/retroarch --verbose --menu 2>&1)` over SSH — it logs a line like `[Autoconf]: Xbox 360 Controller configured in port 1` on success, or silence if nothing matched. DIY/open-source controllers (e.g. GP2040-CE-based sticks) can also present a *different* USB vendor/product ID per input mode (PS4/PS5/XInput/etc.), each needing its own match — switching modes is effectively switching to what RetroArch sees as a different controller.

## Known limitations

- **N64 (`mupen64plus_next`) is flaky to build** upstream — the script installs it best-effort and continues without failing the whole run if it doesn't compile. On the reference Pi this core never ended up installed, matching the original build log's note.
- **The ES-DE Quit-menu source patch is matched against `stable-3.4`.** It's applied as an exact text match against the real upstream source (verified against the actual `stable-3.4` files at build time, and against the compiled binary on the reference Pi via `strings` — the "RESTART EMULATIONSTATION" menu text is present), and fails soft — if you build a different `ESDE_BRANCH` and the surrounding code has changed, the patch step logs a warning and ES-DE still builds, just without that menu entry.
- **Controller button numbers are hardware-specific** and can drift even for the *same* controller (reconnects, firmware mode changes). The defaults shipped here are whatever the reference Pi's controller is actually mapped to right now, captured live via the remap tool — re-capture for your own controller with the in-frontend "Hotkey Config" tool after install regardless.
- **The RetroPie-menu "Splash Screens" tool can silently drop the custom rotation flag.** `splashscreen.cfg`'s `--transform-type=$SPLASH_TRANSFORM_TYPE` is a hand-added option outside what that GUI tool manages: using it to pick/enable a splash video appears to regenerate the file and lose the custom flag (this happened on the reference Pi and was fixed by hand). If your splash video looks unrotated after using that menu, re-run `phase_splash_setup` logic manually or just re-apply the `CMD_OPTS` line shown in [install.sh](install.sh).
- **`SPLASH_TRANSFORM_TYPE` only reliably rotates image splashes, not video ones.** Confirmed by running `vlc -vv` on the reference Pi: h264 video gets hardware-decoded straight to a DRM_PRIME buffer that VLC's `transform` video filter can't process (`Unsupported pixel size 0 (chroma DPV0)`), so VLC logs `removing all filters` and plays the video completely unrotated, regardless of `--transform-type`. This is why the bundled [`splash/retro-splash.mp4`](splash/retro-splash.mp4) has its correct orientation baked directly into the file instead (`ffmpeg -vf transpose=2`, a 90° counter-clockwise/270° clockwise correction for the source clip, verified visually on the reference Pi's actual panel). If you supply your own `SPLASH_VIDEO_URL`, pre-rotate the file the same way rather than relying on `SPLASH_TRANSFORM_TYPE` — it will silently have no effect on video.
- Passwordless polkit reboot/power-off is deliberately granted to `PI_USER` (see below) — appropriate for a dedicated kiosk device, not for a Pi that's also used as a general multi-user machine.

## Security notes

- You're piping a script from the internet into `bash`. Review [install.sh](install.sh) before running it, especially if you're adapting it for other hardware.
- The polkit rule this installs (`/etc/polkit-1/rules.d/50-pi-power.rules`) lets `PI_USER` reboot/power off/suspend the system without authentication, so ES-DE/EmulationStation's own quit-menu actions work with no desktop polkit agent running. This is standard for kiosk-style builds but is a real, systemwide privilege change — remove that file if you don't want it.
- The controller hotkey daemon runs as `root` (`/etc/systemd/system/controller-hotkeys.service`), because writing to the backlight's sysfs brightness file needs elevated permission.

## License

MIT — see [LICENSE](LICENSE).
