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

- Full run time is roughly **1.5–2 hours of actual setup work**, but budget more like **half a day to overnight** if `lr-mame` has to build from source — see [Install time breakdown](#install-time-breakdown) below. It's unattended either way, so this doesn't need babysitting; SSH back in occasionally (or set up a scheduled check) to confirm it's progressing.
- The Pi **reboots itself** at a couple of points (after the base OS update, and after applying display settings if `ENABLE_DSI_DISPLAY=true`). Your SSH session will drop — that's expected. The installer sets up a one-shot `systemd` service that automatically resumes the setup after each reboot, so you don't need to log back in and re-run anything. It removes that service once the whole build is done.
- Progress and errors are logged to `/var/log/pi-arcade-setup.log` on the Pi. If you get disconnected, SSH back in and `tail -f /var/log/pi-arcade-setup.log` to watch progress.
- The script is **safe to re-run**. Every phase is tracked in `/opt/pi-arcade-setup/state`; completed phases are skipped, so if something fails partway (flaky network, a package mirror hiccup) you can just run the same one-liner again.
- By default it reboots into the finished arcade UI when everything is done (`AUTO_REBOOT_AT_END=true`).

### Install time breakdown

Timed end-to-end on the reference Pi (Pi 4, fresh flash) via the installer's own log timestamps:

| Phase | Time | Notes |
|---|---|---|
| Base OS update + display setup | ~15 min | `apt full-upgrade` + one reboot. |
| RetroPie core install (`basic_install`) | ~1h 20min | Once actually running uninterrupted — see caveat below. |
| Emulator/MAME install | **~9 hours** | The dominant cost. This was `lr-mame` compiling from source on-device because no prebuilt binary was available for this platform/OS combo — MAME is a huge codebase and Pi-class hardware is slow at compiling it. If a binary install succeeds instead (depends on your exact OS/board), this phase is minutes, not hours. |
| ES-DE build + everything else (themes, splash, autostart, hotkeys, polkit, custom menu) | ~20 min | |
| **Total** | **~1.5–2 hours of real work, ~9+ hours unattended if MAME builds from source** | |

That reference run's total wall-clock time was actually closer to 17 hours, but roughly 6 of those hours were an early stall/retry loop caused by a passwordless-sudo bug that's since been fixed in this script (see the sudo self-healing logic in `phase_preflight`) — it shouldn't recur on a fresh run. The 9-hour MAME source build is real compute, though, and will happen again on hardware/OS combos without a prebuilt `lr-mame` package.

## What it installs (phase by phase)

1. **Base OS update** — locale (sets `LANG` *and* every `LC_*` category plus `LC_ALL` explicitly, not just `LANG` — `LC_ALL` has the highest precedence, so this is what actually stops a misconfigured SSH client's forwarded locale from producing `bash: warning: setlocale: LC_CTYPE: cannot change locale` over SSH), optional timezone, `apt full-upgrade`, base packages. Reboots once for a clean baseline kernel.
2. **DSI display setup** *(if `ENABLE_DSI_DISPLAY=true`, the default)* — KMS overlay, kernel cmdline rotation, larger console font for the high-DPI panel. Reboots to activate it.
3. **RetroPie** — clones `RetroPie-Setup` and runs `basic_install` (RetroPie core, RetroArch, classic EmulationStation, standard emulator set).
4. **Emulators** — installs `lr-mame` (always) plus the cores listed in `EMULATOR_CORES` (SNES, PS1, PSP, NES, GB/GBC, Genesis, N64, etc. by default).
5. **RetroArch controller autoconfig** — populates RetroArch's *active* autoconfig directory with its full ~440-profile preset library (Xbox, PlayStation, 8BitDo, and hundreds more, matched by USB vendor/product id). Without this, a controller can work fine for menu navigation but do nothing inside actual games — RetroPie only auto-generates an autoconfig profile for a controller you've walked through classic EmulationStation's own input-configuration screen, and ES-DE doesn't do this at all. This closes that gap for any common controller up front.
6. **RetroArch video rotation** — sets `video_allow_rotate = true` and `video_rotation = $RETROARCH_VIDEO_ROTATION` in both `configs/all/retroarch.cfg` and `configs/arcade/retroarch.cfg` (inserted above the arcade config's `#include` line, since RetroArch's config parser only honors the *first* assignment it sees for a key).
7. **File sharing** — ProFTPD, for dropping ROMs onto the Pi over the network.
8. **Disk cleanup** — `apt autoremove`/`clean`.
9. **ES-DE**, built from source (no prebuilt ARM package exists) with `DEINIT_ON_LAUNCH` so it can run directly on the console without a desktop environment.
10. **ES-DE Quit-menu patch** — removes the unreliable "Suspend" option and adds "Restart EmulationStation", by patching ES-DE's C++ source before building it (matched against the real `stable-3.4` source; if a future ES-DE version changes that code, the patch is skipped with a warning rather than failing the whole build).
11. **ES-DE configuration** — first-run default settings, then points it at RetroPie's existing ROM folder and sets the theme/aspect ratio.
12. **Emulator reuse** — symlinks ES-DE to RetroPie's existing RetroArch/PPSSPP install and libretro cores, so nothing is set up twice.
13. **Themes** — clones three ES-DE themes (`artflix-revisited`, `art-book-next`, `alekfull-nx`) and installs the actual curated per-theme artwork (logos, backgrounds, metadata) for the custom RetroPie-menu system from [`theme-art/`](theme-art) in this repo — pulled directly from the reference build, not generated placeholders.
14. **Frontend autostart/switching** — `autostart.sh` boots into whichever frontend is selected, with the restart-loop and clean-shutdown log detection needed to make Quit/Reboot/Power Off/Restart all behave correctly; a `switch-frontend.sh [esde|classic]` helper and an `esde` relaunch command. Also enables console autologin and installs the `/etc/profile.d/10-retropie.sh` trigger (RetroPie's own optional "autostart" module, which `basic_install` does not enable by itself) so the Pi boots straight into the arcade UI instead of a login prompt.
15. **Custom "RetroPie Setup" system in ES-DE** — reproduces classic EmulationStation's built-in config-tools menu (Audio, Bluetooth, File Manager, Raspi-Config, RetroArch, Netplay, RetroPie-Setup, Run Command, Show IP, Splashscreen, WiFi) inside ES-DE, correctly wired through `openvt`+`TERM=linux` so the whiptail/curses tools actually render.
16. **Splash screen** — configures the existing RetroPie splash mechanism's rotation, and downloads a custom splash video from `SPLASH_VIDEO_URL` (defaults to the bundled [`splash/retro-splash.mp4`](splash/retro-splash.mp4) in this repo).
17. **Polkit fix** — grants your user passwordless authorization to reboot/power off/suspend, which headless kiosk setups need (`sudo`'s `NOPASSWD` alone isn't enough — this is a separate polkit-layer permission).
18. **Controller hotkey daemon** — holds L3+R3 while pressing Square/X/Triangle/Circle to adjust screen brightness and volume system-wide, regardless of what has input focus.
19. **In-frontend "Hotkey Config" tool** — a full-screen wizard (reachable from the RetroPie Setup menu inside ES-DE, or `sudo python3 ~/scripts/hotkey-remap.py`) to re-capture your controller's button numbers without SSH.
20. **LED strip daemon** — drives an addressable WS2812B strip via `rpi_ws281x` (hardware DMA-timed output, the same class of approach [WLED](https://kno.wled.ge) itself uses on ESP32 via its RMT peripheral, rather than CPU bit-banging) with twelve effects (solid, flash, breathe, wave, rainbow, chase, theater_chase, bounce, color_wipe, sparkle, confetti, fire), reading color/brightness/speed/LED-count live from a config file so changes from the LED Config tool apply instantly with no restart.
21. **In-frontend "LED Config" tool** — a full-screen wizard (reachable from the RetroPie Setup menu inside ES-DE, or `sudo python3 ~/scripts/led-config.py`) to set the strip's effect, color, brightness, animation speed, and live LED count — fully navigable by controller (left stick to move/adjust, X/Cross to confirm, Circle/B to exit) as well as keyboard.

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
| `RETROARCH_VIDEO_ROTATION` | `90` | RetroArch's `video_rotation` (its own convention: `<n> * 90` degrees counter-clockwise). Applied with `video_allow_rotate = true` to both the global and arcade/MAME RetroArch configs. |
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
| `ENABLE_LED_STRIP` | `true` | Installs the WS2812B LED strip daemon and the in-frontend "LED Config" tool. |
| `LED_GPIO_PIN` | `21` | Data pin for the strip. **Must** be one of GPIO 12/13/18/19 (PWM), 21 (PCM), or 10 (SPI0 MOSI) — the only pins with a hardware DMA-timed peripheral behind them; see [Known limitations](#known-limitations). |
| `LED_COUNT` | `14` | Initial/default live pixel count (adjustable later from the LED Config tool without restarting). |
| `LED_COUNT_MAX` | `150` | Upper bound the LED Config tool can grow the live count to — the strip driver allocates for this many pixels once at startup. |
| `LED_DMA_CHANNEL` | `10` | DMA channel `rpi_ws281x` uses. Only change this if it conflicts with something else using DMA. |
| `LED_PWM_CHANNEL` | `0` | `rpi_ws281x` channel index: `0` for GPIO 12/18/21/10, `1` for GPIO 13/19. |

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
- **`LED_GPIO_PIN` must be one of GPIO 12, 13, 18, 19, 21, or 10.** These are the only pins on the BCM2711 actually wired in silicon to a PWM/PCM/SPI0 peripheral, which `rpi_ws281x` needs for hardware-DMA-timed output — the same class of approach [WLED](https://kno.wled.ge) itself relies on via ESP32's RMT peripheral (confirmed: WLED explicitly avoids pure software bit-banging for exactly this reason). An earlier version of this build tried driving the strip from GPIO4 via a custom CPU busy-loop bit-bang driver; it produced consistently wrong/flickering colors on real hardware regardless of how the software timing was tuned (three different implementations, including one deliberately 3x slower for more margin, all failed identically) - root-caused to GPIO4 having no such peripheral available at all, not a fixable software bug. If you need a pin outside that set, expect the same limitation.
- **Two strips wired in parallel off one data line mirror each other**, not extend to more unique pixels. The reference build's two 14-LED strips share GPIO21, so `LED_COUNT`/`LED_COUNT_MAX` refer to the 14 *unique* addressable pixels both strips display identically — there's no way to address them independently over a single shared data line without daisy-chaining (strip A's data-out into strip B's data-in) instead of paralleling.

## Security notes

- You're piping a script from the internet into `bash`. Review [install.sh](install.sh) before running it, especially if you're adapting it for other hardware.
- The polkit rule this installs (`/etc/polkit-1/rules.d/50-pi-power.rules`) lets `PI_USER` reboot/power off/suspend the system without authentication, so ES-DE/EmulationStation's own quit-menu actions work with no desktop polkit agent running. This is standard for kiosk-style builds but is a real, systemwide privilege change — remove that file if you don't want it.
- The controller hotkey daemon runs as `root` (`/etc/systemd/system/controller-hotkeys.service`), because writing to the backlight's sysfs brightness file needs elevated permission.

## License

MIT — see [LICENSE](LICENSE).
