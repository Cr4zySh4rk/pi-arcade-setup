#!/usr/bin/env bash
#
# pi-arcade-setup / install.sh
#
# Turns a fresh Raspberry Pi OS Lite (64-bit) install into a MAME / RetroPie
# / ES-DE arcade cabinet, following the build documented at:
#   https://github.com/Cr4zySh4rk/pi-arcade-setup
#
# One-line install (run as the normal Pi user that will run the arcade UI,
# e.g. "pi" - do NOT prefix with sudo, the script calls sudo itself):
#
#   curl -fsSL https://raw.githubusercontent.com/Cr4zySh4rk/pi-arcade-setup/main/install.sh | bash
#
# The script is safe to re-run: every phase is tracked in a state file and
# skipped once completed. It survives reboots (base OS updates and, if
# enabled, DSI display changes require one) by installing a one-shot
# systemd service that re-invokes itself on next boot and removes itself
# when the whole build is finished.
#
# See README.md in the repo for the full list of configuration variables.
set -uo pipefail

# --------------------------------------------------------------------------
# 0. Configuration (override any of these via environment variables before
#    running the script, e.g. `ENABLE_DSI_DISPLAY=true curl ... | bash`)
# --------------------------------------------------------------------------

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/Cr4zySh4rk/pi-arcade-setup/main/install.sh}"
STATE_DIR="/opt/pi-arcade-setup"
STATE_FILE="$STATE_DIR/state"
CONFIG_FILE="$STATE_DIR/config.env"
LOG_FILE="/var/log/pi-arcade-setup.log"
SERVICE_FILE="/etc/systemd/system/pi-arcade-setup.service"
SERVICE_NAME="pi-arcade-setup.service"

# User/home the arcade UI will run as. When resumed via systemd this is
# loaded back from config.env, so it stays consistent across reboots.
PI_USER="${PI_USER:-$(whoami)}"
PI_HOME="${PI_HOME:-$HOME}"

LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-}"                     # e.g. "America/New_York"; empty = leave as-is

# --------------------------------------------------------------------------
# 0a. Hardware detection
# --------------------------------------------------------------------------
# Used to gate Raspberry-Pi-only phases (CPU/GPU overclock via config.txt,
# DSI panel overlay, GPIO-driven WS2812 LED strip, and the raspi-config
# console-autologin call) so the script degrades gracefully - skip with a
# warning, not a hard failure - on other Debian-based hardware (another SBC,
# or a generic x86_64/arm64 PC) instead of assuming Pi hardware
# unconditionally everywhere. IMPORTANT: the non-Pi code paths this enables
# (see phase_overclock, phase_display_setup, phase_led_strip_setup,
# phase_autostart_setup) are reasoned through from source/documentation, not
# physically verified - there's no non-Pi hardware in this project's own
# test loop (everything else in this script continues to be verified live
# against the reference Pi 4). Please open an issue if something's wrong
# there on real non-Pi hardware.
#
# Detection reads the device-tree "model" string, which is how the kernel
# itself identifies specific board models - present on Raspberry Pi and
# other ARM SBCs with a device tree, entirely absent on a generic x86_64 PC
# (itself already a reliable "not a Pi" signal). Override with
# IS_RASPBERRY_PI=true/false directly if you ever need to force this.
_detect_raspberry_pi() {
    local model=""
    if [ -r /proc/device-tree/model ]; then
        model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
    elif [ -r /sys/firmware/devicetree/base/model ]; then
        model="$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null || true)"
    fi
    case "$model" in
        Raspberry\ Pi*) echo true ;;
        *) echo false ;;
    esac
}
IS_RASPBERRY_PI="${IS_RASPBERRY_PI:-$(_detect_raspberry_pi)}"

# --------------------------------------------------------------------------
# 0b. Interactive setup wizard
# --------------------------------------------------------------------------
# Asks a short series of questions about this machine's hardware/display and
# derives the variables below from the answers, so a plain `curl ... | bash`
# run on a fresh box - Pi or not, DSI panel or plain HDMI monitor - ends up
# with a correctly-configured install rather than silently inheriting the
# reference build's Pi+DSI-panel assumptions. Only runs when stdin is an
# actual terminal (a piped `curl | bash` has no stdin of its own to read
# answers from - not a bug, just falls back to the documented defaults
# below, which still describe/reproduce the original reference build) and
# this isn't a systemd-resumed run after a reboot (config.env from the
# original interactive run already has the real answers - see main() and
# the EnvironmentFile= line in request_reboot's generated service unit).
# Every question is skipped individually - keeping whatever value is
# already there - if its target variable is already set in the environment,
# so e.g. `ENABLE_DSI_DISPLAY=false curl ... | bash` still short-circuits
# that one question even when run interactively. Skip the whole wizard with
# PI_ARCADE_SKIP_WIZARD=true for a fully unattended/scripted install that
# just wants the plain defaults.
_wizard_ask() {
    # $1=prompt $2=default (shown in brackets; also what a bare Enter picks)
    local prompt="$1" default="$2" reply=""
    read -rp "$prompt [$default]: " reply </dev/tty || reply=""
    echo "${reply:-$default}"
}

run_setup_wizard() {
    [ -t 0 ] || return 0
    [ "${PI_ARCADE_SKIP_WIZARD:-false}" = "true" ] && return 0
    [ "${1:-}" = "--resume" ] && return 0

    echo ""
    echo "=== pi-arcade-setup interactive setup ==="
    echo "Answer a few questions about this machine and its display - press"
    echo "Enter at any prompt to accept the bracketed default. Set"
    echo "PI_ARCADE_SKIP_WIZARD=true beforehand to skip this entirely and"
    echo "use env vars/defaults only (e.g. for a scripted/unattended install)."
    echo ""

    local detected="$IS_RASPBERRY_PI" ans
    ans="$(_wizard_ask "Is this a Raspberry Pi? (auto-detected: $detected)" "$([ "$detected" = true ] && echo y || echo n)")"
    case "$ans" in
        y|Y|yes|true) IS_RASPBERRY_PI=true ;;
        *) IS_RASPBERRY_PI=false ;;
    esac
    [ "$IS_RASPBERRY_PI" = "true" ] || echo "Continuing as generic Debian-based hardware - Pi-only steps (overclock, DSI panel overlay, GPIO LED strip) will be skipped automatically."

    if [ -z "${ENABLE_DSI_DISPLAY+x}" ]; then
        echo ""
        echo "Display:"
        echo "  1) Official/vendor DSI touchscreen panel (this project's reference build used a Waveshare 10.1\" DSI panel)"
        echo "  2) HDMI monitor/TV"
        ans="$(_wizard_ask "Choice" "$([ "$IS_RASPBERRY_PI" = true ] && echo 1 || echo 2)")"
        if [ "$ans" = "1" ] && [ "$IS_RASPBERRY_PI" = "true" ]; then
            ENABLE_DSI_DISPLAY=true
            echo "Using this project's DSI panel defaults (Waveshare 10.1\" DSI Touch A, rotated 90). If you have a different DSI panel, Ctrl-C now and re-run with DSI_OVERLAY/DSI_CMDLINE_ROTATE/FBCON_ROTATE set to match its vendor overlay first - see the README."
        else
            [ "$ans" = "1" ] && echo "DSI panels are a Raspberry-Pi-specific overlay mechanism - treating this as HDMI instead."
            ENABLE_DSI_DISPLAY=false
            echo ""
            ans="$(_wizard_ask "Is the HDMI screen mounted rotated (e.g. a portrait arcade-cabinet monitor)?" "n")"
            case "$ans" in
                y|Y|yes|true)
                    local deg native nw nh
                    deg="$(_wizard_ask "Rotation, clockwise degrees (90/180/270)" "90")"
                    case "$deg" in
                        90|180|270) : ;;
                        *) echo "Unrecognized value, defaulting to 90"; deg=90 ;;
                    esac
                    native="$(_wizard_ask "Screen's native (unrotated) resolution as WIDTHxHEIGHT - check its spec sheet; e.g. a 1920x1080 monitor is still \"1920x1080\" here even mounted sideways" "1920x1080")"
                    nw="${native%x*}"; nh="${native#*x}"
                    { [ "$nw" -gt 0 ] && [ "$nh" -gt 0 ]; } 2>/dev/null || { echo "Unrecognized resolution, defaulting to 1920x1080"; nw=1920; nh=1080; }
                    RETROARCH_VIDEO_ROTATION="$deg"
                    PANEL_NATIVE_WIDTH="$nw"
                    PANEL_NATIVE_HEIGHT="$nh"
                    case "$deg" in
                        90)  ESDE_SCREENROTATE=270; CLASSIC_ES_SCREENROTATE=3; CLASSIC_ES_SCREENSIZE="$nh $nw" ;;
                        180) ESDE_SCREENROTATE=180; CLASSIC_ES_SCREENROTATE=2; CLASSIC_ES_SCREENSIZE="$nw $nh" ;;
                        270) ESDE_SCREENROTATE=90;  CLASSIC_ES_SCREENROTATE=1; CLASSIC_ES_SCREENSIZE="$nh $nw" ;;
                    esac
                    echo "NOTE: this rotated-HDMI mapping is reasoned through from the DSI panel's own working convention (same underlying RetroArch/ES-DE rotation settings, just parameterized off your resolution instead of the panel's), not physically verified on rotated-HDMI hardware yet. If menu/game orientation ends up wrong, RETROARCH_VIDEO_ROTATION/ESDE_SCREENROTATE/CLASSIC_ES_SCREENROTATE are the three values to try adjusting - see the README."
                    ;;
                *)
                    RETROARCH_VIDEO_ROTATION=0
                    ESDE_SCREENROTATE=0
                    CLASSIC_ES_SCREENROTATE=0
                    ;;
            esac
        fi
    fi

    if [ "$IS_RASPBERRY_PI" = "true" ] && [ -z "${ENABLE_OVERCLOCK+x}" ]; then
        echo ""
        ans="$(_wizard_ask "Enable Pi 4 CPU/GPU overclock? (needs real cooling - heatsink+fan case, not passive)" "y")"
        case "$ans" in y|Y|yes|true) ENABLE_OVERCLOCK=true ;; *) ENABLE_OVERCLOCK=false ;; esac
    fi

    if [ "$IS_RASPBERRY_PI" = "true" ] && [ -z "${ENABLE_LED_STRIP+x}" ]; then
        echo ""
        ans="$(_wizard_ask "Enable an addressable WS2812B LED strip wired to a GPIO pin?" "n")"
        case "$ans" in
            y|Y|yes|true)
                ENABLE_LED_STRIP=true
                LED_GPIO_PIN="$(_wizard_ask "GPIO pin (must be 12, 13, 18, 19, 21, or 10 - the ones wired to PWM/PCM/SPI0 in silicon)" "21")"
                ;;
            *) ENABLE_LED_STRIP=false ;;
        esac
    fi

    echo ""
    echo "Setup questions done - starting the install now."
    echo ""
}

run_setup_wizard "${1:-}"

# --- Display (Waveshare 10.1" DSI Touch A in the reference build) ---------
# On by default to reproduce the reference build exactly. Set to "false"
# for a generic HDMI setup with no DSI panel, or point the *_OVERLAY/
# *_ROTATE values at your own panel's vendor-supplied overlay for other
# DSI panels.
ENABLE_DSI_DISPLAY="${ENABLE_DSI_DISPLAY:-true}"
DSI_OVERLAY="${DSI_OVERLAY:-vc4-kms-dsi-waveshare-panel-v2,10_1_inch_a}"
DSI_CMDLINE_ROTATE="${DSI_CMDLINE_ROTATE:-video=DSI-1:800x1280e,rotate=90}"
FBCON_ROTATE="${FBCON_ROTATE:-3}"
ESDE_SCREENROTATE="${ESDE_SCREENROTATE:-270}"          # degrees, ES-DE convention
CLASSIC_ES_SCREENROTATE="${CLASSIC_ES_SCREENROTATE:-3}" # SDL enum, classic ES convention
CLASSIC_ES_SCREENSIZE="${CLASSIC_ES_SCREENSIZE:-1280 800}"
ESDE_THEME_ASPECT="${ESDE_THEME_ASPECT:-16:10}"
CONSOLE_FONT_TWEAK="${CONSOLE_FONT_TWEAK:-$ENABLE_DSI_DISPLAY}"
# RetroArch's own video_rotation (separate from SPLASH_TRANSFORM_TYPE/ES-DE's
# --screenrotate - RetroArch has its own rotation convention entirely: the
# value is <n> * 90 degrees counter-clockwise). Applied to both the global
# config and the arcade/MAME system config in phase_video_rotation_setup.
RETROARCH_VIDEO_ROTATION="${RETROARCH_VIDEO_ROTATION:-90}"
# RetroArch computes its aspect-ratio-fit viewport using the panel's *native*
# (pre-rotation) reported resolution, then rotates the whole result - it does
# not swap width/height for this calculation even when video_rotation is
# active. Confirmed live: with the default auto aspect ratio, content came
# out narrow and tall (correctly sized for a portrait screen, then rotated
# into a landscape one) instead of filling the actual landscape view. The fix
# is a manually-computed custom viewport, expressed in *native* panel
# coordinates (PANEL_NATIVE_WIDTH x PANEL_NATIVE_HEIGHT below), sized/centered
# for a standard 4:3 image so that after rotation it lands as a centered,
# properly-filled box in the real landscape view - see phase_video_rotation_setup
# for the actual math. Also disables video_aspect_ratio_auto (would otherwise
# override this with the same pre-rotation-dimensions bug) and
# video_scale_integer (forces whole-pixel-multiple-only scaling, which left
# most of the screen black on this panel's resolution - confirmed live by
# diffing against a reference build that doesn't set it at all).
PANEL_NATIVE_WIDTH="${PANEL_NATIVE_WIDTH:-800}"
PANEL_NATIVE_HEIGHT="${PANEL_NATIVE_HEIGHT:-1280}"
SPLASH_TRANSFORM_TYPE="${SPLASH_TRANSFORM_TYPE:-90}"    # VLC --transform-type, only used if ENABLE_DSI_DISPLAY
# Custom splash video. Defaults to the bundled reference-build splash
# (splash/retro-splash.mp4 in this repo). NOTE: VLC's --video-filter=transform
# is only reliably applied to *images* on this stack - for h264 video it
# gets hardware-decoded to a DRM_PRIME buffer that the transform filter
# can't process, and VLC silently drops the whole filter chain (confirmed
# via `vlc -vv`: "Unsupported pixel size 0 (chroma DPV0)" -> "removing all
# filters"). So bundled/custom splash videos must have their rotation baked
# into the file itself (e.g. `ffmpeg -i in.mp4 -vf transpose=2 out.mp4` for
# a 90 degree counter-clockwise / 270 clockwise correction, the rotation
# needed for the reference build's landscape source clip on this portrait
# panel) rather than relying on SPLASH_TRANSFORM_TYPE.
SPLASH_VIDEO_URL="${SPLASH_VIDEO_URL:-https://raw.githubusercontent.com/Cr4zySh4rk/pi-arcade-setup/main/splash/retro-splash.mp4}"
DO_RPI_FIRMWARE_UPDATE="${DO_RPI_FIRMWARE_UPDATE:-false}" # runs `rpi-update`; opt-in, only if panel is blank on old firmware

# --- MAME per-game rotation: NOT a per-ROM problem after all -----------------
# An earlier version of this script carried a large phase_mame_rotation_autofix
# mechanism (auto-detecting vertical-cabinet ROMs via a `mame -listxml` dump
# and forcibly setting MAME's own mame_rotation_mode core option per-ROM),
# plus a live L3+R3+Dpad in-game hotkey to re-cycle it. Both were removed
# after diffing a known-good reference SD card against this build and fixing
# the real underlying issues instead - MAME's own default
# mame_rotation_mode="libretro" (auto, per-game) already handles
# vertical-cabinet games correctly with no per-ROM overrides needed at all.
# Forcing mame_rotation_mode="tate-ror" on top of that was actively wrong -
# it double-rotated/stretched vertical games once those real fixes were in
# place. The actual rotation bugs turned out to be the aspect/viewport
# coordinate-space issue and the RGUI/menu source bug fixed in
# phase_video_rotation_setup / phase_retroarch_menu_rotation_patch - an
# earlier pass through this project also blamed the CPU/GPU overclock below,
# but re-enabling it after those real fixes were in place did NOT reproduce
# any rotation problem (confirmed live), so that appears to have been a
# correlation from testing multiple changed settings at once, not an actual
# cause. If rotation regresses again on different hardware, look at the
# aspect/viewport settings and the menu rotation patch first, before
# suspecting the overclock or reintroducing any per-ROM MAME-specific
# mechanism.

# --- CPU/GPU overclock (Raspberry Pi 4 only) --------------------------------
# ON by default. An earlier pass through this project's rotation debugging
# blamed this GPU overclock (gpu_freq above stock 500MHz) for breaking
# RetroArch's rotation, based on a config diff against a known-good reference
# SD card where several settings differed at once. That specific claim did
# NOT hold up under a controlled re-test: with the overclock re-enabled
# alongside the actual fixes (see phase_video_rotation_setup and
# phase_retroarch_menu_rotation_patch), rotation, aspect, and the RGUI/menu
# all displayed correctly, confirmed live. It's kept on by default for the
# performance headroom; if you ever do see a rotation problem, it's worth
# ruling out with ENABLE_OVERCLOCK=false, but treat that as a hypothesis to
# test, not an assumed cause. Scoped under a [pi4] section filter in
# config.txt (see phase_overclock) so it's a no-op on any other board this
# script might run on regardless. Both values are above stock (arm_freq
# 1500MHz / gpu_freq 500MHz) and need the extra core voltage (over_voltage)
# for stability, plus real cooling (heatsink+fan case) to avoid thermal
# throttling under sustained load.
ENABLE_OVERCLOCK="${ENABLE_OVERCLOCK:-true}"
OC_ARM_FREQ="${OC_ARM_FREQ:-2000}"     # CPU, MHz
OC_GPU_FREQ="${OC_GPU_FREQ:-675}"      # VideoCore/GPU core clock, MHz
OC_OVER_VOLTAGE="${OC_OVER_VOLTAGE:-6}" # +0.025V per step; 6 = +0.15V, needed for 2GHz arm_freq

# --- Emulators --------------------------------------------------------------
# MAME is always installed (the point of this script). Additional cores are
# a comma-separated list of RetroPie-Setup package ids.
#
# lr-ppsspp (not "ppsspp"): confirmed live neither the standalone "ppsspp"
# package nor the "lr-ppsspp" libretro core have an aarch64 binary on this
# Debian release (both retropie_packages.sh ... _binary_ calls exit 0 with
# just "Could not find a binary for ..." - the same silent-failure class of
# bug as lr-mesen/lr-fceumm). Unlike those two, there's no other installed
# core for the same system to fall back to for PSP, so phase_emulators_
# install below automatically retries lr-ppsspp with a source build
# (_source_) when its binary install produces nothing - the same pattern
# already used for Flycast and the MAME custom overlay elsewhere in this
# script. lr-ppsspp specifically (not standalone ppsspp) because its output
# (ppsspp_libretro.so) is exactly what ES-DE's own default PSP command
# already expects, so no alternativeEmulator override is needed either -
# see phase_esde_default_emulators.
EMULATOR_CORES="${EMULATOR_CORES:-lr-snes9x,lr-pcsx-rearmed,lr-ppsspp,lr-fceumm,lr-gambatte,lr-genesis-plus-gx,lr-nestopia,lr-picodrive,mupen64plus}"

# Package ids in EMULATOR_CORES that should be retried with a source build
# (_source_) if their binary install doesn't actually produce anything -
# see the lr-ppsspp comment above. Comma-separated; extend this if another
# core in EMULATOR_CORES ever turns out to have the same no-binary problem.
EMULATOR_CORES_SOURCE_FALLBACK="${EMULATOR_CORES_SOURCE_FALLBACK:-lr-ppsspp}"

# --- MAME per-game arcade audio options --------------------------------------
# When true (default), this builds lr-mame from full source with a small
# patch that registers two extra libretro core options - Audio Boost
# (-96..+20dB, using MAME's own live sound_manager mixer routing API, the
# same one the stock Audio Mixer menu uses) and Stereo/Mono (forces a true
# mono downmix when the ROM's emulated sound hardware supports it,
# auto-detected per game from its actual sound_io_device topology at
# runtime - single stereo speaker, split L/R speaker boards, or mono-only -
# falling back to boost-only otherwise). Because these are ordinary libretro
# core options, they show up automatically under RetroArch's own Quick Menu
# > Core Options, AND (via _apply_retroarch_quickmenu_extensions_patch, see
# phase_retroarch_menu_rotation_patch) as a dedicated top-level "Game Audio"
# entry directly in RetroArch's Quick Menu, alongside the Display Brightness
# and Sound entries - one unified in-game overlay reachable with the Home
# button, no separate MAME-only screen. All changes save automatically
# per-game via MAME's existing configuration save on exit, same as any other
# core option.
#
# This is a genuinely large build: compiling MAME's full SUBTARGET=arcade
# target from source on a Pi 4 takes roughly 12 hours and pushes the board
# through sustained heavy memory pressure (confirmed safe on an 8GB Pi 4 with
# swap enabled, but SSH and other services can become briefly unresponsive
# under load during the heaviest files). It is scripted end-to-end (adds
# temporary swap via RetroPie-Setup's own rpSwap mechanism, same as the
# lr-mame scriptmodule's own build path) and requires no manual intervention,
# but budget the time before running with this enabled.
#
# Set to false to skip all of this and install RetroPie's stock lr-mame
# binary instead (fast, but no Audio Boost / Stereo-Mono core options - just
# MAME's normal built-in options).
ENABLE_MAME_ARCADE_AUDIO_OPTIONS="${ENABLE_MAME_ARCADE_AUDIO_OPTIONS:-true}"

# --- Dreamcast (Flycast) -----------------------------------------------------
# Redream (the other well-known Dreamcast emulator) has no real aarch64 Linux
# build - its public source only targets x86_64, the Raspberry Pi/"premium"
# binaries are compiled from a separate closed-source repo, and the official
# binary is known to fail to even start on 64-bit Raspberry Pi OS with the
# modern Mesa v3d KMS driver stack this image uses. Flycast is fully
# open-source, has a real ARM64 JIT backend, and is the standard way
# Dreamcast/Naomi/Atomiswave emulation works on Pi 4 - but RetroPie's binary
# repo has no lr-flycast package for aarch64 on this Debian release either
# (confirmed live: "Could not find a binary for lr-flycast"), so this always
# builds it from source, which needs two fixes of its own - see
# APPLY_GCC14_CFLAGS_PATCH below and _apply_flycast_libzip_patch/
# phase_dreamcast_flycast_install for the details.
ENABLE_DREAMCAST="${ENABLE_DREAMCAST:-true}"

# GameCube/Wii via Dolphin (lr-dolphin). On by default per explicit user
# request, but read phase_gamecube_install's own comment before relying on
# it for anything beyond light/2D-heavy titles - Dolphin's performance on a
# Pi 4 is well documented as poor for most 3D-heavy GameCube games even
# with this project's own CPU/GPU overclock applied. See the README's
# Known limitations entry for the specifics. Set to false to skip it.
ENABLE_GAMECUBE="${ENABLE_GAMECUBE:-true}"

# This OS's default compiler is GCC 14, which made an implicit function
# declaration (calling a function with no visible prototype - almost always
# a missing #include) a hard error by default in C code, where every GCC
# before it only warned. That's correct-by-default behavior upstream, but it
# breaks building a lot of older, otherwise-fine C code unchanged for years,
# including the bundled libzip dependency in Flycast's source tree
# (core/deps/libzip/zip_close.c calls close() but only pulled in
# <unistd.h> on __APPLE__/__SWITCH__, relying on it being available
# transitively elsewhere on Linux - which silently stopped being true here)
# - confirmed live: this specific line is what broke the very first Flycast
# build attempt on this box. Rather than patching every individual instance
# of this class of error that a from-source build might hit (there is
# usually more than one in a codebase this old and this large - a second,
# different instance turned up in libretro-common/glsm/glsm.c on the very
# next build attempt), this patches RetroPie-Setup's own compiler-flags
# setup (scriptmodules/system.sh's single "export CFLAGS=..." line) to add
# -Wno-error=implicit-function-declaration project-wide, downgrading it back
# to a warning - which is what actually let the build finish, since a
# codebase this size may have more of these than any one person building it
# once will discover. This benefits any other module this script (or you,
# later) ever builds from source on this box, not just Flycast.
APPLY_GCC14_CFLAGS_PATCH="${APPLY_GCC14_CFLAGS_PATCH:-true}"

# --- RetroArch source patch (menu rotation) ---------------------------------
# RetroArch's own menu/quick-menu render pass (RGUI) hardcodes an unrotated
# projection matrix in gl2_draw_texture() (gfx/drivers/gl2.c) - a deliberate
# upstream choice to keep the menu upright even when *content* is rotated,
# which backfires when "rotation" is actually compensating for a physically
# rotated panel like this one. No config setting can fix this (confirmed via
# `strings` on the stock binary - no rotation option exists for the menu at
# all) - it needs a source patch and a rebuild. See
# _apply_retroarch_menu_rotation_patch/phase_retroarch_menu_rotation_patch.
# Also fixes a second, MAME-specific bug found afterward: some cores (MAME,
# for ROT90 arcade games like Pac-Man) call the libretro
# RETRO_ENVIRONMENT_SET_ROTATION callback, which overwrites RetroArch's
# internal rotation value with just the core's own raw request instead of
# combining it with this script's panel-rotation config - harmless for game
# content (MAME separately pre-rotates its own frame buffer to compensate)
# but left the *menu* rotated wrong specifically during MAME sessions once
# the first patch made it share that same value. The patch below builds a
# separate rotation matrix for the menu from the config's video_rotation
# alone, so it's unaffected by whatever any given core requests.
# Also fixes a third bug found later, once Bezel Project overlay bezels
# were added to this project: gl2_render_overlay() (the function that
# draws a RetroArch input_overlay, e.g. a Bezel Project cabinet/console
# bezel) hardcodes that same unrotated gl->mvp_no_rot matrix regardless of
# video_rotation, same as the menu did - confirmed live: an otherwise
# correctly-installed NES bezel pack rendered rotated 90 degrees relative
# to the (correctly rotated) game beneath it. Unlike the menu, an overlay
# is tied to actual game content, so it's patched to use gl->mvp (the same
# already-rotated matrix content itself draws with) rather than a
# separate config-only matrix like the menu needs.
APPLY_RETROARCH_MENU_ROTATION_PATCH="${APPLY_RETROARCH_MENU_ROTATION_PATCH:-true}"

# --- ES-DE --------------------------------------------------------------
ESDE_BRANCH="${ESDE_BRANCH:-stable-3.4}"
APPLY_ESDE_QUITMENU_PATCH="${APPLY_ESDE_QUITMENU_PATCH:-true}"
# Fixes a genuine upstream ES-DE 3.4.1 crash: opening Main Menu > Scraper
# (GuiScraperMenu's constructor, es-app/src/guis/GuiScraperMenu.cpp) builds
# the "SCRAPE THESE SYSTEMS" list by looping over SystemData::sSystemVector
# with index i, but calls mSystems->add(...) only for systems that don't
# have PlatformIds::PLATFORM_IGNORE - then immediately calls
# mSystems->selectEntry(i)/unselectEntry(i) using that SAME outer index i,
# not the position actually reached inside mSystems. Any ignored system
# before the end of sSystemVector (this project's own "RetroPie Setup"
# custom system, step 15, is deliberately tagged <platform>ignore</platform>
# so it isn't scraped, and sorts before every real system alphabetically)
# makes every subsequent selectEntry/unselectEntry call run one or more
# indices past the end of mSystems's actual entry list - an out-of-bounds
# access that throws unconditionally, is never caught, and terminates the
# whole process (std::terminate -> SIGABRT) with no ES-DE log line and no
# kernel-visible fault, since the crash happens before any scraper-specific
# code path would log anything. Confirmed live via a debug-logged capture
# of the crash (nothing at all between the Start button press that opens
# the Main Menu and the process exiting) and by reading the actual
# GuiScraperMenu.cpp source this build compiles. Fixed by tracking a
# separate counter for the index actually reached inside mSystems.
APPLY_ESDE_SCRAPER_MENU_PATCH="${APPLY_ESDE_SCRAPER_MENU_PATCH:-true}"
INSTALL_THEMES="${INSTALL_THEMES:-true}"
ESDE_THEME_NAME="${ESDE_THEME_NAME:-artflix-revisited}"
INITIAL_FRONTEND="${INITIAL_FRONTEND:-esde}"            # esde | classic
# Console autologin + boot-time launch trigger (RetroPie's own "autostart"
# module - see phase_autostart_setup). Off only makes sense if you intend
# to wire up autostart some other way yourself.
ENABLE_CONSOLE_AUTOSTART="${ENABLE_CONSOLE_AUTOSTART:-true}"

# Pins the aux/headphone jack as the default PipeWire/WirePlumber audio
# output (see phase_audio_output_setup) - this build has no HDMI-audio
# display, so HDMI should never be picked as the output even if something
# later gets plugged into it.
ENABLE_AUX_AUDIO_FORCE="${ENABLE_AUX_AUDIO_FORCE:-true}"
# Shared "confirm"/"back" button roles used by this project's various
# in-frontend RetroPie-menu tools (LED Config, Bluetooth pairing, etc.) -
# not specific to any one tool.
BTN_X="${BTN_X:-0}"
BTN_CIRCLE="${BTN_CIRCLE:-1}"

# --- Addressable LED strip ---------------------------------------------------
# WS2812B strip(s) on the reference build (two 14-LED strips wired in
# parallel off one data line, so they mirror each other - 14 unique
# addressable pixels total), driven via rpi_ws281x on GPIO21 (PCM_DOUT).
# rpi_ws281x uses the Pi's PWM/PCM peripheral + DMA for genuine
# hardware-timed output - the same class of approach WLED uses on ESP32
# (RMT + DMA) rather than CPU bit-banging - which only works on pins wired
# to that peripheral in silicon: GPIO 12/13/18/19 (PWM), 21 (PCM), or 10
# (SPI0 MOSI). An earlier version of this build tried bit-banging GPIO4
# directly (that's not one of those pins); it was unreliable on real
# hardware and was dropped - see phase_led_strip_setup's comment for why.
ENABLE_LED_STRIP="${ENABLE_LED_STRIP:-true}"
LED_GPIO_PIN="${LED_GPIO_PIN:-21}"
LED_COUNT="${LED_COUNT:-14}"
# Upper bound the in-frontend LED Config tool can grow LED_COUNT to (it's
# live-adjustable there, not just at install time - see led-config.py). The
# strip driver is allocated for this many pixels once at startup regardless
# of the live count, so it can go up or down instantly with no restart.
LED_COUNT_MAX="${LED_COUNT_MAX:-150}"
LED_DMA_CHANNEL="${LED_DMA_CHANNEL:-10}"
LED_PWM_CHANNEL="${LED_PWM_CHANNEL:-0}"   # rpi_ws281x channel index: 0 for GPIO 12/18/21/10, 1 for GPIO 13/19

# --- MP3 player ---------------------------------------------------------------
# Local music player (RetroPie menu -> "Music Player"), playing files from
# MUSIC_DIR via VLC (python-vlc bindings). Runs as the normal Pi user - no
# background service, it's a foreground tool like Hotkey Config/LED Config.
ENABLE_MUSIC_PLAYER="${ENABLE_MUSIC_PLAYER:-true}"
MUSIC_DIR="${MUSIC_DIR:-$PI_HOME/RetroPie/Music}"

# --- Bezel Project (RetroArch overlay bezels) ---------------------------------
# Installs thebezelproject/BezelProject's own bezelproject.sh - an
# interactive, dialog-based tool (RetroPie menu -> "Bezel Project") for
# downloading per-system RetroArch overlay bezels (a PNG frame drawn around
# the game, matching original arcade cabinet/console artwork; needs ROMs
# named to the No-Intro convention to match up). This only installs the
# tool itself, exactly as thebezelproject's own install instructions do
# (a single script dropped into the RetroPie menu folder) - which systems'
# bezel packs to actually download and enable is left up to you to choose
# interactively from the tool's own menu, since each pack is a sizeable
# per-system git clone and there's no sensible unattended default for
# "which systems do you play". IMPORTANT: read this project's own README
# Known limitations entry on this before enabling the "MAME" bezel pack -
# confirmed by reading the tool's own source, it strips this project's
# aspect_ratio/custom_viewport lines from /opt/retropie/configs/arcade/
# retroarch.cfg when applied, which undoes the vertical-cabinet rotation/
# aspect fix documented in step 6 above.
ENABLE_BEZEL_PROJECT="${ENABLE_BEZEL_PROJECT:-true}"

# --- Bluetooth speaker ---------------------------------------------------------
# Turns the Pi into an A2DP sink advertised as BT_SPEAKER_NAME, via BlueALSA
# (bluealsa + bluealsa-aplay - see phase_bt_speaker_setup for why PipeWire/
# WirePlumber's own bluez5 monitor isn't used instead) plus this project's
# own headless auto-accept pairing agent. RetroPie menu -> "Bluetooth Player"
# shows AVRCP now-playing metadata from the connected phone and can send it
# play/pause/next/prev, car-head-unit style. Unlike the LED strip daemon, the
# Pi only actively behaves as a Bluetooth audio device - discoverable to new
# phones, holding/reconnecting a paired phone's A2DP link - while that tool
# is open; closing it disconnects any phone and reverts the Pi to a plain
# Bluetooth host, so a paired game controller isn't sharing the radio with
# an idle audio link the rest of the time.
ENABLE_BT_SPEAKER="${ENABLE_BT_SPEAKER:-true}"
BT_SPEAKER_NAME="${BT_SPEAKER_NAME:-RetroPieArcade}"

AUTO_REBOOT_AT_END="${AUTO_REBOOT_AT_END:-true}"

# --------------------------------------------------------------------------
# 1. Small helpers
# --------------------------------------------------------------------------

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()      { echo "[$(_ts)] [pi-arcade-setup] $*" | sudo tee -a "$LOG_FILE" >/dev/null; echo "[$(_ts)] $*"; }
log_warn() { log "WARNING: $*"; }
log_err()  { log "ERROR: $*"; }
die()      { log_err "$*"; exit 1; }

phase_done() {
    [ -f "$STATE_FILE" ] && grep -qxF "$1" "$STATE_FILE"
}

mark_done() {
    echo "$1" | sudo tee -a "$STATE_FILE" >/dev/null
}

run_phase() {
    local name="$1"
    if phase_done "$name"; then
        log "Skipping phase '$name' (already completed)"
        return 0
    fi
    # Exposed so request_reboot() can mark this phase done before it exits
    # the process (a phase that reboots never returns to the "if" below).
    CURRENT_PHASE="$name"
    log "==> Starting phase: $name"
    if "phase_$name"; then
        mark_done "$name"
        log "==> Finished phase: $name"
    else
        die "Phase '$name' failed. Re-run the installer to retry (completed phases are skipped)."
    fi
}

# Persist the current config so a post-reboot systemd resume uses the same
# settings the user originally chose.
write_config_file() {
    sudo mkdir -p "$STATE_DIR"
    sudo tee "$CONFIG_FILE" >/dev/null <<EOF
IS_RASPBERRY_PI=$IS_RASPBERRY_PI
PI_USER=$PI_USER
PI_HOME=$PI_HOME
LOCALE=$LOCALE
TIMEZONE=$TIMEZONE
ENABLE_DSI_DISPLAY=$ENABLE_DSI_DISPLAY
DSI_OVERLAY=$DSI_OVERLAY
DSI_CMDLINE_ROTATE=$DSI_CMDLINE_ROTATE
FBCON_ROTATE=$FBCON_ROTATE
ESDE_SCREENROTATE=$ESDE_SCREENROTATE
CLASSIC_ES_SCREENROTATE=$CLASSIC_ES_SCREENROTATE
CLASSIC_ES_SCREENSIZE=$CLASSIC_ES_SCREENSIZE
ESDE_THEME_ASPECT=$ESDE_THEME_ASPECT
CONSOLE_FONT_TWEAK=$CONSOLE_FONT_TWEAK
RETROARCH_VIDEO_ROTATION=$RETROARCH_VIDEO_ROTATION
PANEL_NATIVE_WIDTH=$PANEL_NATIVE_WIDTH
PANEL_NATIVE_HEIGHT=$PANEL_NATIVE_HEIGHT
SPLASH_TRANSFORM_TYPE=$SPLASH_TRANSFORM_TYPE
SPLASH_VIDEO_URL=$SPLASH_VIDEO_URL
DO_RPI_FIRMWARE_UPDATE=$DO_RPI_FIRMWARE_UPDATE
ENABLE_OVERCLOCK=$ENABLE_OVERCLOCK
OC_ARM_FREQ=$OC_ARM_FREQ
OC_GPU_FREQ=$OC_GPU_FREQ
OC_OVER_VOLTAGE=$OC_OVER_VOLTAGE
EMULATOR_CORES=$EMULATOR_CORES
EMULATOR_CORES_SOURCE_FALLBACK=$EMULATOR_CORES_SOURCE_FALLBACK
ENABLE_MAME_ARCADE_AUDIO_OPTIONS=$ENABLE_MAME_ARCADE_AUDIO_OPTIONS
ENABLE_DREAMCAST=$ENABLE_DREAMCAST
ENABLE_GAMECUBE=$ENABLE_GAMECUBE
APPLY_GCC14_CFLAGS_PATCH=$APPLY_GCC14_CFLAGS_PATCH
APPLY_RETROARCH_MENU_ROTATION_PATCH=$APPLY_RETROARCH_MENU_ROTATION_PATCH
ESDE_BRANCH=$ESDE_BRANCH
APPLY_ESDE_QUITMENU_PATCH=$APPLY_ESDE_QUITMENU_PATCH
APPLY_ESDE_SCRAPER_MENU_PATCH=$APPLY_ESDE_SCRAPER_MENU_PATCH
INSTALL_THEMES=$INSTALL_THEMES
ESDE_THEME_NAME=$ESDE_THEME_NAME
INITIAL_FRONTEND=$INITIAL_FRONTEND
ENABLE_CONSOLE_AUTOSTART=$ENABLE_CONSOLE_AUTOSTART
ENABLE_AUX_AUDIO_FORCE=$ENABLE_AUX_AUDIO_FORCE
BTN_X=$BTN_X
BTN_CIRCLE=$BTN_CIRCLE
ENABLE_LED_STRIP=$ENABLE_LED_STRIP
LED_GPIO_PIN=$LED_GPIO_PIN
LED_COUNT=$LED_COUNT
LED_COUNT_MAX=$LED_COUNT_MAX
LED_DMA_CHANNEL=$LED_DMA_CHANNEL
LED_PWM_CHANNEL=$LED_PWM_CHANNEL
ENABLE_MUSIC_PLAYER=$ENABLE_MUSIC_PLAYER
MUSIC_DIR=$MUSIC_DIR
ENABLE_BEZEL_PROJECT=$ENABLE_BEZEL_PROJECT
ENABLE_BT_SPEAKER=$ENABLE_BT_SPEAKER
BT_SPEAKER_NAME=$BT_SPEAKER_NAME
AUTO_REBOOT_AT_END=$AUTO_REBOOT_AT_END
EOF
}

# Ensure our own copy of the script is persisted on disk (so a systemd
# resume after reboot has something stable to execute) and install/enable
# the resume service. Reboots the machine and exits.
request_reboot() {
    local reason="$1"
    log "Reboot required: $reason"

    # This phase is complete as far as its own work goes - mark it done
    # *before* rebooting, since this function exits the process and never
    # returns to run_phase()'s own mark_done call. Without this, resuming
    # after reboot would see the phase as not-done and re-run it (and hit
    # this same reboot again) forever.
    if [ -n "${CURRENT_PHASE:-}" ]; then
        mark_done "$CURRENT_PHASE"
    fi

    sudo mkdir -p "$STATE_DIR"
    if [ ! -f "$STATE_DIR/install.sh" ]; then
        log "Persisting installer to $STATE_DIR/install.sh"
        if ! sudo curl -fsSL "$SCRIPT_URL" -o "$STATE_DIR/install.sh"; then
            log_warn "Could not re-download installer from $SCRIPT_URL; copying current script instead"
            sudo cp -- "$0" "$STATE_DIR/install.sh"
        fi
        sudo chmod +x "$STATE_DIR/install.sh"
    fi
    write_config_file

    if [ ! -f "$SERVICE_FILE" ]; then
        log "Installing $SERVICE_NAME to resume setup on next boot"
        sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Resume pi-arcade-setup after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$PI_USER
WorkingDirectory=$PI_HOME
EnvironmentFile=$CONFIG_FILE
ExecStart=$STATE_DIR/install.sh --resume
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
    fi
    sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

    log "Rebooting now. Setup will continue automatically after boot (watch $LOG_FILE)."
    sleep 2
    sudo systemctl reboot
    # systemctl reboot returns immediately; stop this run here.
    exit 0
}

remove_resume_service() {
    if [ -f "$SERVICE_FILE" ]; then
        log "Removing resume service (setup complete)"
        sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        sudo rm -f "$SERVICE_FILE"
        sudo systemctl daemon-reload
    fi
}

require_cmd() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# 2. Phases
# --------------------------------------------------------------------------

phase_preflight() {
    [ "$(id -u)" -eq 0 ] && die "Run this script as your normal Pi user (e.g. 'pi'), not as root/with sudo. It calls sudo itself where needed."
    require_cmd sudo || die "sudo is required"

    # Newer Raspberry Pi OS images (Bookworm/Trixie, user created via
    # Imager) do NOT ship the old hardcoded passwordless-sudo file for the
    # first user the way legacy "pi" images did - sudo may require a
    # password. This script has to run non-interactively across reboots
    # (a systemd service resumes it, with no terminal to type a password
    # into), so passwordless sudo is a hard requirement, not just a nicety.
    # Fix it now, once, while a human is actually present at this terminal
    # to enter a password if prompted.
    if ! sudo -n true 2>/dev/null; then
        log "Passwordless sudo isn't set up for $PI_USER yet - configuring it now (you may be prompted for your password once)."
        sudo -v || die "Could not authenticate with sudo for $PI_USER. This installer requires sudo access."
        local sudoers_file="/etc/sudoers.d/010_${PI_USER}-nopasswd"
        echo "$PI_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee "$sudoers_file" >/dev/null
        sudo chmod 440 "$sudoers_file"
        if ! sudo visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
            sudo rm -f "$sudoers_file"
            die "Generated sudoers rule failed validation; refusing to install a broken sudoers file. Configure passwordless sudo for $PI_USER manually (visudo) and re-run."
        fi
        sudo -n true 2>/dev/null || die "Still could not get passwordless sudo working for $PI_USER after configuring $sudoers_file. Please check it and re-run."
        log "Passwordless sudo configured for $PI_USER ($sudoers_file)."
    fi
    grep -qi "raspbian\|raspberry pi os\|debian" /etc/os-release 2>/dev/null || log_warn "This doesn't look like Raspberry Pi OS/Debian - continuing anyway, but things may not match the reference build."
    sudo mkdir -p "$STATE_DIR"
    sudo touch "$LOG_FILE"
    sudo chmod 666 "$LOG_FILE" 2>/dev/null || true
    write_config_file
    return 0
}

phase_overclock() {
    if [ "$IS_RASPBERRY_PI" != "true" ]; then
        log "IS_RASPBERRY_PI=false, skipping (arm_freq/gpu_freq/over_voltage in config.txt are Raspberry-Pi-specific; this hardware isn't one)"
        return 0
    fi
    if [ "$ENABLE_OVERCLOCK" != "true" ]; then
        log "ENABLE_OVERCLOCK=false, skipping"
        return 0
    fi

    local cfg="/boot/firmware/config.txt"
    [ -f "$cfg" ] || cfg="/boot/config.txt"
    [ -f "$cfg" ] || { log_warn "config.txt not found at /boot/firmware/config.txt or /boot/config.txt; skipping overclock"; return 0; }

    # Idempotent re-run: strip any block this phase previously added (by its
    # marker comments) before reappending the current desired values, rather
    # than leaving stale/duplicate arm_freq|gpu_freq|over_voltage lines
    # behind if OC_* was changed and the installer re-run.
    sudo python3 - "$cfg" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read()
text = re.sub(
    r"\n?# --- pi-arcade-setup overclock \(BEGIN\) ---.*?# --- pi-arcade-setup overclock \(END\) ---\n?",
    "\n", text, flags=re.DOTALL,
)
with open(path, "w") as f:
    f.write(text.rstrip("\n") + "\n")
PYEOF

    # Scoped under the [pi4] conditional filter (a real config.txt feature,
    # not a comment) so this is a harmless no-op if the script's ever run on
    # different Raspberry Pi hardware - arm_freq/over_voltage are exactly the
    # kind of values that shouldn't silently carry over to a different SoC.
    # Appended at the end of the file and closed with a trailing [all] so it
    # can't accidentally swallow whatever section header the file happened
    # to end on (e.g. this build's own DSI overlay under [all]) into [pi4].
    sudo tee -a "$cfg" >/dev/null <<EOF

# --- pi-arcade-setup overclock (BEGIN) ---
# Raspberry Pi 4 only. Bumps the CPU to ${OC_ARM_FREQ}MHz (stock 1500MHz) and
# the GPU/VideoCore core clock to ${OC_GPU_FREQ}MHz (stock 500MHz), with the
# extra core voltage (over_voltage=${OC_OVER_VOLTAGE}, +${OC_OVER_VOLTAGE} *
# 0.025V) these clocks need for stability. Requires real cooling (heatsink +
# fan case, not passive) to avoid thermal throttling under sustained load.
# Takes effect on next reboot - check "vcgencmd get_throttled" afterwards
# (0x0 = never throttled) and "vcgencmd measure_clock arm"/"measure_clock
# core" to confirm the new clocks actually applied.
[pi4]
over_voltage=$OC_OVER_VOLTAGE
arm_freq=$OC_ARM_FREQ
gpu_freq=$OC_GPU_FREQ
[all]
# --- pi-arcade-setup overclock (END) ---
EOF

    log "Overclock written to $cfg (arm_freq=$OC_ARM_FREQ gpu_freq=$OC_GPU_FREQ over_voltage=$OC_OVER_VOLTAGE) - reboot required to take effect"
    request_reboot "applying CPU/GPU overclock"
}

phase_base_update() {
    sudo sed -i "s/^# *\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen 2>/dev/null || true
    sudo locale-gen || true
    # raspi-config's do_change_locale (and a plain update-locale) only ever
    # set LANG, leaving LC_ALL and the individual LC_* categories unset.
    # That's normally fine since unset LC_* falls back to LANG - but if an
    # SSH client forwards a broken/incomplete LANG or LC_* value (a common
    # terminal quirk; sshd's default `AcceptEnv LANG LC_*` lets it through),
    # bash ends up spamming:
    #   bash: warning: setlocale: LC_CTYPE: cannot change locale (UTF-8): No such file or directory
    # LC_ALL has the highest precedence and overrides anything a client
    # forwards, so setting it explicitly (in both /etc/default/locale and
    # /etc/environment) sidesteps this regardless of what the SSH client sends.
    local locale_lang="${LOCALE%%.*}"       # e.g. en_US
    local locale_short="${locale_lang%%_*}" # e.g. en
    sudo tee /etc/default/locale >/dev/null <<LOCEOF
LANG=$LOCALE
LANGUAGE=${locale_lang}:${locale_short}
LC_CTYPE="$LOCALE"
LC_NUMERIC="$LOCALE"
LC_TIME="$LOCALE"
LC_COLLATE="$LOCALE"
LC_MONETARY="$LOCALE"
LC_MESSAGES="$LOCALE"
LC_PAPER="$LOCALE"
LC_NAME="$LOCALE"
LC_ADDRESS="$LOCALE"
LC_TELEPHONE="$LOCALE"
LC_MEASUREMENT="$LOCALE"
LC_IDENTIFICATION="$LOCALE"
LC_ALL=$LOCALE
LOCEOF
    grep -q "^LANG=$LOCALE" /etc/environment 2>/dev/null || echo "LANG=$LOCALE" | sudo tee -a /etc/environment >/dev/null
    grep -q "^LC_ALL=$LOCALE" /etc/environment 2>/dev/null || echo "LC_ALL=$LOCALE" | sudo tee -a /etc/environment >/dev/null
    if [ -n "$TIMEZONE" ]; then
        sudo raspi-config nonint do_change_timezone "$TIMEZONE" 2>/dev/null || sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null || log_warn "Could not set timezone to $TIMEZONE"
    fi
    sudo apt-get update -y || die "apt-get update failed"
    sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y || die "apt-get full-upgrade failed"
    sudo apt-get install -y git dialog unzip xmlstarlet curl ca-certificates util-linux || die "base package install failed"
    df -h / | sudo tee -a "$LOG_FILE" >/dev/null

    # The onboard Cypress/Infineon BCM4345/6 WiFi chip on this Pi has a
    # long-standing, still-unresolved upstream firmware bug where association
    # to a real, in-range, correctly-configured AP fails outright - not a
    # scan/visibility/password problem. Confirmed live: wpa_supplicant logs
    # `CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16`
    # (the all-zero bssid means this is generated locally by the
    # driver/firmware, not a real rejection frame from the AP) on every
    # single association attempt, for two different real networks, both
    # confirmed visible with a strong signal via a raw `iw scan`, both with
    # the correct password already stored in the connection profile. This is
    # a widely-reported bug on this exact chip (see
    # https://github.com/RPi-Distro/firmware-nonfree/issues/38 and
    # https://forums.raspberrypi.com/viewtopic.php?t=377009) with no official
    # fix as of this writing. The most consistently-reported community
    # workaround - disabling the driver's own roaming logic - resolved it
    # immediately on the reference Pi (confirmed live: failed on every
    # attempt before this, connected on the very first attempt after
    # rebooting with it in place, with a real IP and working internet).
    # Requires the reboot below to reload the brcmfmac module with this
    # option; harmless if your hardware never hits this bug in the first
    # place (roaming isn't used on a stationary kiosk device anyway).
    echo 'options brcmfmac roamoff=1' | sudo tee /etc/modprobe.d/brcmfmac.conf >/dev/null
    log "Disabled brcmfmac WiFi roaming (roamoff=1) to work around a known BCM4345/6 association-failure bug - see comment above"

    # WiFi power-save mode is a separate, well-documented source of flaky
    # associations/drops on this same Broadcom chip. It wasn't the cause of
    # the specific bug above (confirmed: still failed identically with this
    # already off), but it's a real, independent failure mode worth ruling
    # out permanently on a device that's meant to just stay connected.
    # NetworkManager doesn't ship this disabled by default.
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<'PSEOF'
[connection]
wifi.powersave = 2
PSEOF
    log "Disabled WiFi power-save via NetworkManager (wifi.powersave = 2)"

    # A kernel/bootloader update via full-upgrade is common on Pi OS and can
    # leave later steps (display driver, builds) on a stale running kernel -
    # always reboot once after this phase for a clean baseline.
    request_reboot "base OS update/upgrade"
}

phase_display_setup() {
    if [ "$ENABLE_DSI_DISPLAY" != "true" ]; then
        log "ENABLE_DSI_DISPLAY=false, skipping DSI display configuration"
        return 0
    fi
    if [ "$IS_RASPBERRY_PI" != "true" ]; then
        log_warn "ENABLE_DSI_DISPLAY=true but IS_RASPBERRY_PI=false - the dtoverlay/config.txt mechanism this phase uses is Raspberry-Pi-specific, so there's nothing correct to do here on this hardware. Skipping; set ENABLE_DSI_DISPLAY=false (the default the setup wizard picks for non-Pi hardware) if this is intentional, or IS_RASPBERRY_PI=true if detection got this wrong."
        return 0
    fi

    local cfg="/boot/firmware/config.txt"
    [ -f "$cfg" ] || cfg="/boot/config.txt"

    if ! grep -q "dtoverlay=vc4-kms-v3d" "$cfg" 2>/dev/null; then
        echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$cfg" >/dev/null
    fi
    if ! grep -qF "$DSI_OVERLAY" "$cfg" 2>/dev/null; then
        echo "dtoverlay=$DSI_OVERLAY" | sudo tee -a "$cfg" >/dev/null
    fi
    grep -q "^disable_fw_kms_setup=1" "$cfg" 2>/dev/null || echo "disable_fw_kms_setup=1" | sudo tee -a "$cfg" >/dev/null

    local cmdline="/boot/firmware/cmdline.txt"
    [ -f "$cmdline" ] || cmdline="/boot/cmdline.txt"
    if [ -f "$cmdline" ] && ! grep -qF "$DSI_CMDLINE_ROTATE" "$cmdline"; then
        sudo cp "$cmdline" "${cmdline}.bak.$(date +%s)"
        sudo sed -i "1 s/\$/ $DSI_CMDLINE_ROTATE/" "$cmdline"
    fi

    if [ "$CONSOLE_FONT_TWEAK" = "true" ]; then
        if ! grep -q 'FONTFACE="Terminus"' /etc/default/console-setup 2>/dev/null; then
            sudo tee -a /etc/default/console-setup >/dev/null <<'EOF'
FONTFACE="Terminus"
FONTSIZE="28x14"
EOF
            sudo setupcon --force --save 2>/dev/null || true
        fi
    fi

    if [ "$DO_RPI_FIRMWARE_UPDATE" = "true" ]; then
        log "DO_RPI_FIRMWARE_UPDATE=true, running rpi-update (this can take a while)"
        sudo cp "$cfg" "${cfg}.bak.$(date +%s)"
        sudo rpi-update || log_warn "rpi-update failed/unavailable; continuing"
    fi

    request_reboot "activating DSI display overlay / rotation"
}

phase_verify_display() {
    if [ "$ENABLE_DSI_DISPLAY" = "true" ]; then
        cat /sys/class/graphics/fbcon/rotate 2>/dev/null | sudo tee -a "$LOG_FILE" >/dev/null || true
        if [ "$(cat /sys/class/graphics/fbcon/rotate 2>/dev/null)" != "$FBCON_ROTATE" ]; then
            echo "$FBCON_ROTATE" | sudo tee /sys/class/graphics/fbcon/rotate >/dev/null 2>&1 || \
                log_warn "fbcon rotate is not $FBCON_ROTATE and could not be set directly; console text may render rotated until a udev rule sets it at boot."
        fi
    fi
    return 0
}

phase_retropie_install() {
    if [ ! -d "$PI_HOME/RetroPie-Setup" ]; then
        git clone --depth=1 https://github.com/RetroPie/RetroPie-Setup.git "$PI_HOME/RetroPie-Setup" || die "clone RetroPie-Setup failed"
    fi
    cd "$PI_HOME/RetroPie-Setup" || die "cannot cd into RetroPie-Setup"
    log "Running RetroPie basic_install - this is long-running (can exceed an hour on a Pi 4)"
    # basic_install walks dozens of packages, each fetching sources/binaries
    # from GitHub or files.retropie.org.uk; a single transient network blip
    # partway through (confirmed live: a retroarch-minimal-assets.tar.gz
    # download failed once, even though the URL was reachable seconds later)
    # kills the whole multi-hour run otherwise. retropie_packages.sh's own
    # per-package update-check ("Update is available - updating ...") makes
    # re-running basic_install cheap/idempotent for already-built packages,
    # so retry a few times with a short backoff before giving up for real.
    local attempt
    local out
    out="$(mktemp)"
    for attempt in 1 2 3; do
        if sudo ./retropie_packages.sh setup basic_install 2>&1 | tee "$out"; then
            [ -x /opt/retropie/supplementary/emulationstation/emulationstation ] || command -v emulationstation >/dev/null 2>&1 || log_warn "emulationstation binary not found where expected after basic_install"
            rm -f "$out"
            return 0
        fi
        # RetroPie-Setup's own splashscreen scriptmodule tries `git checkout rpi`
        # (falling back to `git checkout master`) as part of configuring the
        # splashscreen repo. Upstream RetroPie/retropie-splashscreens no longer
        # has an 'rpi' branch (confirmed live: only master/reorganisation exist),
        # so the checkout always fails there and falls back to master, which
        # succeeds and leaves the splashscreen correctly configured - but
        # RetroPie-Setup still records it as an error, which makes
        # retropie_packages.sh's own exit status non-zero even though nothing
        # is actually broken. That failure is deterministic, so blindly
        # retrying 3 times would just burn ~an hour re-walking the whole
        # package list for no reason and then die() permanently. Detect this
        # specific known-benign case and treat it as success instead.
        local other_errors
        other_errors="$(grep -E "^Error running " "$out" | grep -vE "^Error running 'git checkout (rpi|master)' - returned 128$" || true)"
        if grep -q "^Errors:$" "$out" && [ -z "$other_errors" ]; then
            log_warn "RetroPie basic_install reported only the known-benign splashscreen 'git checkout rpi' branch-fallback error (upstream retropie-splashscreens has no 'rpi' branch anymore); treating as success"
            [ -x /opt/retropie/supplementary/emulationstation/emulationstation ] || command -v emulationstation >/dev/null 2>&1 || log_warn "emulationstation binary not found where expected after basic_install"
            rm -f "$out"
            return 0
        fi
        log_warn "RetroPie basic_install failed (attempt $attempt/3)"
        [ "$attempt" -lt 3 ] && sleep 30
    done
    rm -f "$out"
    die "RetroPie basic_install failed after 3 attempts"
}

# See the APPLY_GCC14_CFLAGS_PATCH comment above for the full story. A tiny,
# single-line patch to RetroPie-Setup's own compiler-flags setup - applied
# once, right after cloning it, so every module built from source afterward
# (not just Flycast) picks it up. Fail-soft like the other source patches:
# skips with a warning rather than failing the whole install if a future
# RetroPie-Setup version changes this line.
_apply_gcc14_cflags_patch() {
    local rp_setup_dir="$1"
    python3 - "$rp_setup_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
path = root / "scriptmodules/system.sh"
text = path.read_text()

old = 'export CFLAGS="$__cflags"'
new = 'export CFLAGS="$__cflags -Wno-error=implicit-function-declaration"'

if new in text:
    print("[patch] system.sh GCC14 CFLAGS fix: already applied")
    sys.exit(0)
if old not in text:
    print("[patch] system.sh GCC14 CFLAGS fix: anchor text not found, skipping (RetroPie-Setup source may have changed)")
    sys.exit(3)
path.write_text(text.replace(old, new, 1))
print("[patch] system.sh GCC14 CFLAGS fix: applied")
sys.exit(0)
PYEOF
}

phase_gcc14_cflags_patch() {
    if [ "$APPLY_GCC14_CFLAGS_PATCH" != "true" ]; then
        log "APPLY_GCC14_CFLAGS_PATCH=false, skipping"
        return 0
    fi
    _apply_gcc14_cflags_patch "$PI_HOME/RetroPie-Setup" || log_warn "GCC14 CFLAGS patch did not apply; building any module from source (e.g. Flycast) may fail on this OS's GCC 14 with an implicit-function-declaration error."
    return 0
}

phase_emulators_install() {
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    if [ "$ENABLE_MAME_ARCADE_AUDIO_OPTIONS" = "true" ]; then
        log "Skipping stock lr-mame binary install - ENABLE_MAME_ARCADE_AUDIO_OPTIONS=true, a source build with the extra Audio Boost/Stereo-Mono core options happens in a later phase instead"
    else
        log "Installing MAME (lr-mame)"
        sudo ./retropie_packages.sh lr-mame _binary_ || die "lr-mame install failed"
    fi

    local core sys fallback_cores
    IFS=',' read -ra fallback_cores <<< "$EMULATOR_CORES_SOURCE_FALLBACK"
    IFS=',' read -ra cores <<< "$EMULATOR_CORES"
    for core in "${cores[@]}"; do
        [ -z "$core" ] && continue
        log "Installing emulator core: $core"
        sudo ./retropie_packages.sh "$core" _binary_
        # retropie_packages.sh can exit non-zero on a non-fatal post-install
        # step (e.g. gamelist/scriptmodule bookkeeping) even though the
        # package itself installed fine - so don't trust the exit code
        # alone. Only actually warn if nothing landed on disk for it.
        local core_dir="/opt/retropie/libretrocores/$core"
        [ -d "$core_dir" ] || core_dir="/opt/retropie/emulators/$core"
        local has_so=false
        if [ -d "$core_dir" ] && compgen -G "$core_dir"/*_libretro.so >/dev/null 2>&1; then
            has_so=true
        elif [ -d "$core_dir" ] && [ -n "$(find "$core_dir" -maxdepth 1 -type f -executable 2>/dev/null)" ]; then
            has_so=true  # standalone (non-libretro) emulator package
        fi
        if [ "$has_so" = false ]; then
            local is_fallback=false
            local fc
            for fc in "${fallback_cores[@]}"; do
                [ "$fc" = "$core" ] && is_fallback=true && break
            done
            if [ "$is_fallback" = true ]; then
                log_warn "$core has no aarch64 binary (confirmed: retropie_packages.sh reports \"Could not find a binary\") - falling back to a source build. This can take a while (PPSSPP: roughly 30-60 min on a Pi 4)."
                sudo ./retropie_packages.sh "$core" _source_ \
                    || log_warn "$core source build failed - continuing without it, see the RetroPie-Setup build output above for the actual compiler error"
                if compgen -G "/opt/retropie/libretrocores/$core"/*_libretro.so >/dev/null 2>&1; then
                    log "$core: source build succeeded"
                else
                    log_warn "$core: source build did not produce a .so either - this system will stay unavailable until that's fixed upstream or by hand"
                fi
            else
                log_warn "$core does not appear to be installed (this is a known flaky step for some cores, e.g. mupen64plus/N64 upstream) - continuing without it"
            fi
        fi
    done

    for sys in snes psx psp arcade nes gb gbc megadrive n64 dreamcast; do
        mkdir -p "$PI_HOME/RetroPie/roms/$sys"
    done
    return 0
}

# NOTE (superseded design): MAME's own in-game menu used to be hijacked to
# open a ~600-line custom ui::menu subclass (menu_arcade_overlay) offering
# audio boost / stereo-mono controls, bypassing MAME's stock menu_main
# entirely. That has been replaced by the implementation below: MAME's own
# menu is left completely stock (its IPT_UI_MENU hotkey is untouched), and
# the audio boost / stereo-mono controls are instead exposed as two ordinary
# libretro core options ("Game Audio" category) which RetroArch's own Quick
# Menu > Core Options screen already renders generically - and which are
# ALSO surfaced as a dedicated top-level "Game Audio" entry directly in
# RetroArch's Quick Menu by _apply_retroarch_quickmenu_extensions_patch
# (see phase_retroarch_menu_rotation_patch). This is both much smaller
# (2 new option entries + a small check_variables()/retro_run() hook vs. an
# entire menu subclass + ui.cpp/frontend.lua hooks) and matches how the
# user actually wants this surfaced: as part of the single RetroArch
# overlay menu, not a separate MAME-only screen.
#
# Patches two files in a freshly-cloned lr-mame source checkout:
#   src/osd/libretro/libretro_core_options.h - registers the "game_audio"
#     option category and the two new options (mame_arcade_audio_boost_db,
#     mame_arcade_audio_stereo) in MAME's existing, already-working
#     core-options machinery (option_cats_us[]/option_defs_us[], consumed
#     generically by libretro_set_core_options()) - no changes needed there.
#   src/osd/libretro/libretro.cpp - adds free functions that read those two
#     option values and apply them to the running game's sound_manager
#     routing (ported from the old menu_arcade_overlay class's
#     scan_devices/apply_boost/apply_stereo/clear_all_routes/find_node_name
#     methods, adapted to take a running_machine& instead of member access),
#     hooked into check_variables() (fires whenever RetroArch signals an
#     option changed) and into retro_run()'s first-frame block (a safety net
#     ensuring a per-game persisted value is actually applied even if
#     check_variables() ran too early, before mame_machine_manager had a
#     running_machine yet).
# Both patches are idempotent and anchor-checked, matching every other
# source patch in this script (see _apply_flycast_libzip_patch for the same
# pattern).
_apply_mame_arcade_overlay_patch() {
    local mame_src_dir="$1"
    # libretro/mame's master branch moved these two files into a
    # src/osd/libretro/libretro-internal/ subdirectory at some point after
    # this patch was first written against the old src/osd/libretro/ layout
    # (confirmed live: a fresh clone no longer has them at the old path) -
    # try the current location first, falling back to the old one so this
    # keeps working if it ever moves back or a pinned older checkout is used.
    local opts_h="$mame_src_dir/src/osd/libretro/libretro-internal/libretro_core_options.h"
    local lr_cpp="$mame_src_dir/src/osd/libretro/libretro-internal/libretro.cpp"
    if [ ! -f "$opts_h" ] || [ ! -f "$lr_cpp" ]; then
        opts_h="$mame_src_dir/src/osd/libretro/libretro_core_options.h"
        lr_cpp="$mame_src_dir/src/osd/libretro/libretro.cpp"
    fi

    if [ ! -f "$opts_h" ] || [ ! -f "$lr_cpp" ]; then
        echo "[patch] mame core-options: libretro_core_options.h or libretro.cpp not found under $mame_src_dir/src/osd/libretro(-internal) - MAME source layout may have changed, skipping"
        return 3
    fi

    python3 - "$opts_h" "$lr_cpp" <<'PYEOF'
import sys

opts_path, cpp_path = sys.argv[1], sys.argv[2]
rc = 0

# ---------------------------------------------------------------
# libretro_core_options.h: add the "game_audio" category and the
# two new options (dB boost + stereo/mono) to MAME's existing,
# already-working core-options tables.
# ---------------------------------------------------------------
text = open(opts_path).read()

old_cat_tail = '''   {
      "hacks",
      "Emulation Hacks",
      "Configure emulation hack options."
   },
   { NULL, NULL, NULL },
};'''
new_cat_tail = '''   {
      "hacks",
      "Emulation Hacks",
      "Configure emulation hack options."
   },
   {
      "game_audio",
      "Game Audio",
      "Per-game audio boost and stereo/mono downmix, also mirrored as a dedicated 'Game Audio' entry in RetroArch's own Quick Menu."
   },
   { NULL, NULL, NULL },
};'''
if new_cat_tail in text:
    print("[patch] libretro_core_options.h category: already applied")
elif old_cat_tail not in text:
    print("[patch] libretro_core_options.h category: anchor text not found, skipping (MAME source may have changed)")
    rc = 3
else:
    text = text.replace(old_cat_tail, new_cat_tail, 1)
    print("[patch] libretro_core_options.h category: applied")

db_choices = []
for n in range(-96, 21):
    label = f'{n:+d} dB' if n != 0 else '0 dB'
    db_choices.append(f'         {{ "{n}", "{label}" }},')
db_choices_block = "\n".join(db_choices)

old_defs_tail = '''         { "20", NULL },
         { NULL, NULL },
      },
      "0"
   },
   { NULL, NULL, NULL, NULL, NULL, NULL, {{0}}, NULL },
};'''
new_defs_tail = '''         { "20", NULL },
         { NULL, NULL },
      },
      "0"
   },
   {
      CORE_NAME "_arcade_audio_boost_db",
      "Arcade Audio Boost (dB)",
      NULL,
      "Uniform gain applied on top of the current arcade game's normal sound mixer routing. Takes effect immediately and is saved per-game. Also mirrored as 'Game Audio > Audio Boost' in RetroArch's own Quick Menu.",
      NULL,
      "game_audio",
      {
''' + db_choices_block + '''
         { NULL, NULL },
      },
      "0"
   },
   {
      CORE_NAME "_arcade_audio_stereo",
      "Arcade Audio Stereo/Mono",
      NULL,
      "Toggles between true stereo and a mono downmix (both channels summed, each attenuated 6 dB to avoid clipping) for the current arcade game's sound output. Takes effect immediately and is saved per-game. Also mirrored as 'Game Audio > Stereo/Mono' in RetroArch's own Quick Menu.",
      NULL,
      "game_audio",
      {
         { "stereo", "Stereo" },
         { "mono", "Mono" },
         { NULL, NULL },
      },
      "stereo"
   },
   { NULL, NULL, NULL, NULL, NULL, NULL, {{0}}, NULL },
};'''
if new_defs_tail in text:
    print("[patch] libretro_core_options.h definitions: already applied")
elif old_defs_tail not in text:
    print("[patch] libretro_core_options.h definitions: anchor text not found, skipping (MAME source may have changed)")
    rc = 3
else:
    text = text.replace(old_defs_tail, new_defs_tail, 1)
    print("[patch] libretro_core_options.h definitions: applied")

open(opts_path, "w").write(text)

# ---------------------------------------------------------------
# libretro.cpp: includes, helper functions, and the two call sites
# (check_variables() tail, retro_run()'s first_run block).
# ---------------------------------------------------------------
text = open(cpp_path).read()

old_inc = '''#include "libretro.h"
#include "libretro_shared.h"
#include "libretro_core_options.h"
#include "libretro_vfs.h"'''
new_inc = '''#include "libretro.h"
#include "libretro_shared.h"
#include "libretro_core_options.h"
#include "libretro_vfs.h"

#include "speaker.h"

#include <vector>
#include <algorithm>
#include <cstdlib>'''
if new_inc in text:
    print("[patch] libretro.cpp includes: already applied")
elif old_inc not in text:
    print("[patch] libretro.cpp includes: anchor text not found, skipping (MAME source may have changed)")
    rc = 3
else:
    text = text.replace(old_inc, new_inc, 1)
    print("[patch] libretro.cpp includes: applied")

helper_marker = "/* pi-arcade-setup: per-game audio boost / stereo-mono */"
helper_block = helper_marker + '''
enum class pi_arcade_layout_type
{
   NONE,
   SINGLE_MULTI,
   SINGLE_MONO,
   SPLIT_STEREO,
   OTHER
};

static float pi_arcade_last_boost_db              = 0.0f;
static bool  pi_arcade_last_stereo                = true;
static bool  pi_arcade_audio_options_initialized  = false;

static pi_arcade_layout_type pi_arcade_scan_layout(running_machine &machine, std::vector<sound_io_device *> &out_devs)
{
   out_devs.clear();
   for (const auto &omap : machine.sound().get_mappings())
      if (omap.m_dev && omap.m_dev->is_output())
         out_devs.push_back(omap.m_dev);

   if (out_devs.empty())
      return pi_arcade_layout_type::NONE;
   if (out_devs.size() == 1)
      return (out_devs[0]->inputs() >= 2) ? pi_arcade_layout_type::SINGLE_MULTI : pi_arcade_layout_type::SINGLE_MONO;
   if (out_devs.size() == 2 && out_devs[0]->inputs() == 1 && out_devs[1]->inputs() == 1)
      return pi_arcade_layout_type::SPLIT_STEREO;
   return pi_arcade_layout_type::OTHER;
}

static std::string pi_arcade_find_node_name(running_machine &machine, uint32_t node)
{
   const auto &info = machine.sound().get_osd_info();
   for (const auto &n : info.m_nodes)
      if (n.m_id == node)
         return n.name();
   return "";
}

static void pi_arcade_clear_all_routes(running_machine &machine, sound_io_device *dev)
{
   for (;;)
   {
      bool changed = false;
      for (const auto &omap : machine.sound().get_mappings())
      {
         if (omap.m_dev != dev)
            continue;

         if (!omap.m_node_mappings.empty())
         {
            const auto &nmap = omap.m_node_mappings.front();
            if (nmap.m_is_system_default)
               machine.sound().config_remove_sound_io_connection_default(dev);
            else
               machine.sound().config_remove_sound_io_connection_node(dev, pi_arcade_find_node_name(machine, nmap.m_node));
            changed = true;
         }
         else if (!omap.m_channel_mappings.empty())
         {
            const auto &cmap = omap.m_channel_mappings.front();
            if (cmap.m_is_system_default)
               machine.sound().config_remove_sound_io_channel_connection_default(dev, cmap.m_guest_channel, cmap.m_node_channel);
            else
               machine.sound().config_remove_sound_io_channel_connection_node(dev, cmap.m_guest_channel, pi_arcade_find_node_name(machine, cmap.m_node), cmap.m_node_channel);
            changed = true;
         }
         break;
      }
      if (!changed)
         break;
   }
}

static void pi_arcade_apply_audio_options(running_machine &machine, float boost_db, bool stereo)
{
   std::vector<sound_io_device *> out_devs;
   const pi_arcade_layout_type layout = pi_arcade_scan_layout(machine, out_devs);
   const bool want_downmix = !stereo && (layout == pi_arcade_layout_type::SINGLE_MULTI || layout == pi_arcade_layout_type::SPLIT_STEREO);

   if (layout == pi_arcade_layout_type::SINGLE_MULTI)
   {
      sound_io_device *const dev = out_devs[0];
      pi_arcade_clear_all_routes(machine, dev);
      if (!want_downmix)
      {
         machine.sound().config_add_sound_io_connection_default(dev, boost_db);
      }
      else
      {
         const float ch_db = boost_db - 6.0f;
         const uint32_t guest_channels = std::min<uint32_t>(2, dev->inputs());
         for (uint32_t g = 0; g < guest_channels; g++)
            for (uint32_t n = 0; n < 2; n++)
               machine.sound().config_add_sound_io_channel_connection_default(dev, g, n, ch_db);
      }
   }
   else if (layout == pi_arcade_layout_type::SPLIT_STEREO)
   {
      for (size_t i = 0; i < out_devs.size() && i < 2; i++)
      {
         sound_io_device *const dev = out_devs[i];
         pi_arcade_clear_all_routes(machine, dev);
         if (!want_downmix)
         {
            machine.sound().config_add_sound_io_channel_connection_default(dev, 0, uint32_t(i), boost_db);
         }
         else
         {
            const float ch_db = boost_db - 6.0f;
            machine.sound().config_add_sound_io_channel_connection_default(dev, 0, 0, ch_db);
            machine.sound().config_add_sound_io_channel_connection_default(dev, 0, 1, ch_db);
         }
      }
   }
   else
   {
      /* NONE / SINGLE_MONO / OTHER: no meaningful stereo/mono topology
         change available - just re-apply gain to whatever routes already
         exist (or add a default one if none exist yet), unchanged. */
      for (sound_io_device *dev : out_devs)
      {
         bool any = false;
         for (const auto &omap : machine.sound().get_mappings())
         {
            if (omap.m_dev != dev)
               continue;
            for (const auto &nmap : omap.m_node_mappings)
            {
               if (nmap.m_is_system_default)
                  machine.sound().config_set_volume_sound_io_connection_default(dev, boost_db);
               else
                  machine.sound().config_set_volume_sound_io_connection_node(dev, pi_arcade_find_node_name(machine, nmap.m_node), boost_db);
               any = true;
            }
            for (const auto &cmap : omap.m_channel_mappings)
            {
               if (cmap.m_is_system_default)
                  machine.sound().config_set_volume_sound_io_channel_connection_default(dev, cmap.m_guest_channel, cmap.m_node_channel, boost_db);
               else
                  machine.sound().config_set_volume_sound_io_channel_connection_node(dev, cmap.m_guest_channel, pi_arcade_find_node_name(machine, cmap.m_node), cmap.m_node_channel, boost_db);
               any = true;
            }
            break;
         }
         if (!any)
            machine.sound().config_add_sound_io_connection_default(dev, boost_db);
      }
   }
}

static void pi_arcade_check_audio_variables(void)
{
   struct retro_variable var = {0};
   bool changed = !pi_arcade_audio_options_initialized;

   var.key   = CORE_NAME "_arcade_audio_boost_db";
   var.value = NULL;
   if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var) && var.value)
   {
      const float db = (float)atof(var.value);
      if (db != pi_arcade_last_boost_db)
      {
         pi_arcade_last_boost_db = db;
         changed = true;
      }
   }

   var.key   = CORE_NAME "_arcade_audio_stereo";
   var.value = NULL;
   if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var) && var.value)
   {
      const bool stereo = !strcmp(var.value, "stereo");
      if (stereo != pi_arcade_last_stereo)
      {
         pi_arcade_last_stereo = stereo;
         changed = true;
      }
   }

   if (!changed)
      return;

   if (   mame_machine_manager::instance() != NULL
       && mame_machine_manager::instance()->machine() != NULL)
   {
      pi_arcade_apply_audio_options(*mame_machine_manager::instance()->machine(), pi_arcade_last_boost_db, pi_arcade_last_stereo);
      pi_arcade_audio_options_initialized = true;
   }
}
'''

old_cv_tail = '''   var.key   = CORE_NAME "_media_type";
   var.value = NULL;
   if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var) && var.value)
   {
      sprintf(mediaType,"-%s",var.value);
   }
}'''
new_cv_tail = '''   var.key   = CORE_NAME "_media_type";
   var.value = NULL;
   if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var) && var.value)
   {
      sprintf(mediaType,"-%s",var.value);
   }

   pi_arcade_check_audio_variables();
}'''

if helper_marker in text:
    print("[patch] libretro.cpp helper functions: already applied")
elif old_cv_tail not in text:
    print("[patch] libretro.cpp check_variables() hook: anchor text not found, skipping (MAME source may have changed)")
    rc = 3
else:
    # Insert the helper block immediately before check_variables()'s own
    # definition, then hook its tail.
    cv_def = "static void check_variables(void)"
    idx = text.find(cv_def)
    if idx == -1:
        print("[patch] libretro.cpp: check_variables() definition not found, skipping")
        rc = 3
    else:
        text = text[:idx] + helper_block + "\n" + text[idx:]
        text = text.replace(old_cv_tail, new_cv_tail, 1)
        print("[patch] libretro.cpp helper functions + check_variables() hook: applied")

old_first_run = '''   if (first_run)
   {
      /* Skip drawing the first frame due to a gray border */
      first_run       = false;
      draw_this_frame = false;
   }'''
new_first_run = '''   if (first_run)
   {
      /* Skip drawing the first frame due to a gray border */
      first_run       = false;
      draw_this_frame = false;

      /* pi-arcade-setup: safety net - apply the per-game persisted audio
         boost/stereo options here too, in case check_variables() ran
         earlier (from retro_load_game()) before mame_machine_manager had
         a running_machine yet. Idempotent: no-ops if already applied. */
      pi_arcade_check_audio_variables();
   }'''
if "safety net - apply the per-game persisted audio" in text:
    print("[patch] libretro.cpp retro_run() hook: already applied")
elif old_first_run not in text:
    print("[patch] libretro.cpp retro_run() hook: anchor text not found, skipping (MAME source may have changed)")
    rc = 3
else:
    text = text.replace(old_first_run, new_first_run, 1)
    print("[patch] libretro.cpp retro_run() hook: applied")

open(cpp_path, "w").write(text)
sys.exit(rc)
PYEOF
    local status=$?
    if [ $status -ne 0 ]; then
        return $status
    fi
    return 0
}


# Builds MAME (lr-mame) from source with the extra Audio Boost / Stereo-Mono
# core options - see ENABLE_MAME_ARCADE_AUDIO_OPTIONS above. Mirrors the
# exact sources/patch/_source_ sequence phase_dreamcast_flycast_install uses
# for Flycast (see that phase's own comment for why retropie_packages.sh is
# split into two calls rather than one).
phase_mame_arcade_overlay_build() {
    if [ "$ENABLE_MAME_ARCADE_AUDIO_OPTIONS" != "true" ]; then
        log "ENABLE_MAME_ARCADE_AUDIO_OPTIONS=false, stock prebuilt MAME from phase_emulators_install stands"
        return 0
    fi
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    log "Fetching MAME source"
    sudo ./retropie_packages.sh lr-mame sources || die "lr-mame sources step failed"

    # retropie_packages.sh's "sources" step runs as root (via the sudo
    # above), so the cloned tree is root-owned - confirmed live
    # (PermissionError writing libretro_core_options.h as $PI_USER without
    # this). Hand it back to $PI_USER before patching as a plain user below;
    # the subsequent "_source_" build step re-invokes retropie_packages.sh
    # with sudo again regardless, so this doesn't affect the build itself.
    sudo chown -R "$PI_USER:$PI_USER" "$PI_HOME/RetroPie-Setup/tmp/build/lr-mame" \
        || log_warn "Could not chown MAME source tree to $PI_USER - the patch step below may fail with a permission error"

    _apply_mame_arcade_overlay_patch "$PI_HOME/RetroPie-Setup/tmp/build/lr-mame" \
        || log_warn "MAME arcade audio core-options patch did not fully apply - build may fail, or may succeed but without the extra Audio Boost/Stereo-Mono options, if MAME's source has changed since this script was written"

    log "Building MAME with the extra Audio Boost/Stereo-Mono core options - full arcade subtarget build, confirmed ~12 hours wall-clock on a Pi 4 with -j4"
    sudo ./retropie_packages.sh lr-mame _source_ || die "lr-mame build/install failed"

    if [ ! -f /opt/retropie/libretrocores/lr-mame/mamearcade_libretro.so ]; then
        die "mamearcade_libretro.so not found after build - MAME emulation would not be available at all, aborting"
    fi

    # Verify the build actually linked completely, not just that the file
    # exists. Confirmed live: a prior run of this exact phase (unmodified -
    # RetroPie's own lr-mame scriptmodule already does "make clean" before
    # building, so this isn't a stale-incremental-build issue) produced a
    # mamearcade_libretro.so that *looked* fine - the file was present,
    # RetroArch loaded the core without complaint, and non-DRC drivers
    # (e.g. Pac-Man's plain Z80, no dynamic recompiler involved) booted
    # straight to gameplay - but the linker had silently dropped the
    # object implementing MAME's ARM64 dynamic-recompiler backend. Any
    # driver whose CPU cores use MAME's UML/DRC framework (SH-2 as in
    # Street Fighter III/CPS3, TMS34010 as in Mortal Kombat, MIPS3, etc. -
    # a large slice of the arcade driver list) hard-crashed the instant
    # that code path was first hit, with "undefined symbol:
    # ...make_drcbe_arm64...". RetroArch's own dlopen() is lazy-bound, so
    # it never surfaces this at core-load time - only when a specific ROM
    # actually calls into the missing code. Force eager symbol resolution
    # here (LD_BIND_NOW) so an incomplete link is caught immediately as a
    # loud build failure instead of shipping a core that silently crashes
    # on an unpredictable subset of ROMs.
    if ! LD_BIND_NOW=1 python3 -c "
import ctypes, sys
try:
    ctypes.CDLL('/opt/retropie/libretrocores/lr-mame/mamearcade_libretro.so')
except OSError as e:
    print(e, file=sys.stderr)
    sys.exit(1)
"; then
        die "mamearcade_libretro.so was built but failed an eager-symbol-resolution check (undefined symbol at link time) - the build silently produced an incomplete binary that would boot simple ROMs fine but crash on anything using MAME's DRC CPU cores. Re-run this phase (retropie_packages.sh lr-mame _source_ again); if it keeps recurring, see the Known Limitations note in README.md"
    fi
    return 0
}

# Fixes the specific implicit-function-declaration error confirmed live in
# Flycast's bundled libzip dependency (core/deps/libzip/zip_close.c calls
# close() but only #includes <unistd.h> on __APPLE__/__SWITCH__) - see the
# ENABLE_DREAMCAST comment above. This one is patched directly (rather than
# just relying on the project-wide GCC14 CFLAGS downgrade above) since it's
# a genuine missing-include bug worth actually fixing at the source, not
# just silencing - the GCC14 patch is what catches whatever *other* such
# bugs remain elsewhere in a codebase this size (confirmed live: there was
# at least one more, in libretro-common/glsm/glsm.c).
_apply_flycast_libzip_patch() {
    local flycast_src_dir="$1"
    python3 - "$flycast_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
path = root / "core/deps/libzip/zip_close.c"
if not path.exists():
    print("[patch] zip_close.c GCC14 include fix: file not found, skipping (Flycast source may have changed)")
    sys.exit(3)
text = path.read_text()

old = """#if defined(__APPLE__) || defined(__SWITCH__)
#include <unistd.h>
#endif"""
new = "#include <unistd.h>"

if new in text and old not in text:
    print("[patch] zip_close.c GCC14 include fix: already applied")
    sys.exit(0)
if old not in text:
    print("[patch] zip_close.c GCC14 include fix: anchor text not found, skipping (Flycast source may have changed)")
    sys.exit(3)
path.write_text(text.replace(old, new, 1))
print("[patch] zip_close.c GCC14 include fix: applied")
sys.exit(0)
PYEOF
}

# Installs Flycast (lr-flycast) for Dreamcast/Naomi/Atomiswave emulation -
# see the ENABLE_DREAMCAST comment above for why this isn't Redream, and why
# this always builds from source. Modeled on how the RetroArch/ES-DE source
# patches in this script work, but split into separate retropie_packages.sh
# calls (sources, then build+install+configure+clean via the "_source_"
# meta-mode) rather than one chained call - confirmed live that
# retropie_packages.sh only ever acts on the *first* mode argument given to
# it; a plain module name with no mode (or the literal "_source_") is the
# one exception that internally chains depends/sources/build/install/
# configure/clean, which is what this relies on for the second call.
phase_dreamcast_flycast_install() {
    if [ "$ENABLE_DREAMCAST" != "true" ]; then
        log "ENABLE_DREAMCAST=false, skipping"
        return 0
    fi
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    log "Fetching Flycast source"
    sudo ./retropie_packages.sh lr-flycast sources || die "lr-flycast sources step failed"

    _apply_flycast_libzip_patch "$PI_HOME/RetroPie-Setup/tmp/build/lr-flycast" \
        || log_warn "Flycast libzip patch did not fully apply; build may fail on GCC 14 if the source has changed - the project-wide GCC14 CFLAGS patch may still cover it."

    log "Building Flycast (Dreamcast/Naomi/Atomiswave) - this can take 10-15 min on a Pi 4"
    sudo ./retropie_packages.sh lr-flycast _source_ || die "lr-flycast build/install failed"

    if [ ! -f /opt/retropie/libretrocores/lr-flycast/flycast_libretro.so ]; then
        log_warn "flycast_libretro.so not found after install; Dreamcast emulation will not be available"
        return 0
    fi

    mkdir -p "$PI_HOME/.config/retroarch/cores"
    ln -sf /opt/retropie/libretrocores/lr-flycast/flycast_libretro.so "$PI_HOME/.config/retroarch/cores/flycast_libretro.so"

    # mame-tools provides chdman, used by fix-dreamcast-roms.py below - see
    # that script's own header comment for why this is needed: a multi-track
    # GD-ROM dump (.gdi/.cue + separate track .bin files) fails to load in
    # Flycast when packaged inside a .zip/.7z archive at all (confirmed live
    # - not a folder-layout issue, an inherent limitation of loading a
    # multi-file disc set from inside an archive), and converting it to a
    # single-file .chd is the fix.
    sudo apt-get install -y mame-tools || log_warn "mame-tools install failed; chdman won't be available, so fix-dreamcast-roms.py can't convert archived multi-track GDI/CUE ROMs to .chd"

    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/fix-dreamcast-roms.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Fixes a real Dreamcast ROM packaging problem confirmed live on this exact
Flycast/RetroArch build: a multi-track GD-ROM dump (a .gdi or .cue index
file plus several separate track .bin files) fails to load when it's
packaged inside a .zip/.7z archive, regardless of how the files are laid
out inside that archive. Flycast's own disc-reading code needs to open
each track file by a path relative to the .gdi/.cue - something the
libretro archive/VFS layer here doesn't support - so it can't find a valid
disc at all and falls back to trying to load the archive as a totally
different content type (a raw Naomi arcade cartridge ROM), which fails
with something like:
    W[NAOMI]: Unknown game <name>
    E[NAOMI]: Cannot load ...: error 22
and kicks straight back to the frontend with no visible error. This was
confirmed NOT to be about the internal folder layout of the archive
(flattening a nested folder to the archive root made no difference) - it's
an inherent limitation of loading a multi-file GDI/CUE set from inside an
archive at all. Loading the exact same .gdi directly as a plain file
works correctly, and single-file disc image formats (.cdi, .chd) also
work fine whether or not real disc data is present.

The fix: convert any archived multi-track GDI/CUE set to a single-file
.chd (MAME's Compressed Hunks of Data format, via the "chdman" tool from
the mame-tools package) - Flycast loads a .chd natively, with no
archive/sibling-file issue possible since it's one self-contained file.
This replaces the original .zip/.7z with a same-named .chd, typically
around 10-20% of the original size.

This script also fixes a separate, independent problem: some downloaded
archives are actually 7z data saved with a .zip extension (or the
reverse) - RetroArch picks its archive parser from the file extension, so
a mismatched one means it can't read the archive at all. That's fixed
here too, for any archive this script touches.

Only .cdi/.chd files (single-file disc images) already stored directly as
a plain file, and .zip/.7z archives containing only a single-file disc
image with nothing else, are left alone - both are already known to load
correctly and don't need any of this.

Run any time after adding new Dreamcast ROMs via FTP/SFTP:
    python3 ~/scripts/fix-dreamcast-roms.py
Safe to re-run - anything already in a working state is left untouched.

Generated by pi-arcade-setup.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROMS_DIR = "$PI_HOME/RetroPie/roms/dreamcast"
DISC_INDEX_EXTS = (".gdi", ".cue")


def have_chdman():
    return shutil.which("chdman") is not None


def real_archive_type(path):
    out = subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout
    if "7-zip archive" in out:
        return "7z"
    if "Zip archive" in out:
        return "zip"
    return None


def list_entries(path, kind):
    """Returns a list of *file* entry paths (directory entries excluded).

    For 7z archives this uses "7z l -slt" (one "Key = Value" line per
    field, one block per entry) rather than the column-aligned "7z l"
    output - solid archives only print a "Packed Size" for the first
    entry in a block and leave it blank for the rest, which silently
    shifts every column after it in the plain listing and truncates any
    name containing spaces (confirmed live)."""
    if kind == "7z":
        out = subprocess.run(["7z", "l", "-slt", path], capture_output=True, text=True).stdout
        if "----------" in out:
            out = out.split("----------", 1)[1]
        else:
            out = ""
        names = []
        cur_path, cur_is_dir = None, False
        for line in out.splitlines():
            if line.startswith("Path = "):
                if cur_path is not None and not cur_is_dir:
                    names.append(cur_path.strip("/"))
                cur_path, cur_is_dir = line[len("Path = "):], False
            elif line.startswith("Folder = "):
                cur_is_dir = line[len("Folder = "):].strip() == "+"
            elif line.startswith("Attributes = "):
                if line[len("Attributes = "):].strip().startswith("D"):
                    cur_is_dir = True
        if cur_path is not None and not cur_is_dir:
            names.append(cur_path.strip("/"))
        return names
    out = subprocess.run(["unzip", "-Z1", path], capture_output=True, text=True).stdout
    return [line.strip("/") for line in out.splitlines() if line.strip() and not line.endswith("/")]


def fix_extension(path, kind):
    ext = os.path.splitext(path)[1].lower()
    expect_ext = "." + kind
    if ext == expect_ext:
        return path
    new_path = os.path.splitext(path)[0] + expect_ext
    if os.path.exists(new_path):
        print(f"[skip] {os.path.basename(path)}: wrong extension for its content (actually {kind}), "
              f"but {os.path.basename(new_path)} already exists - not overwriting")
        return None
    os.rename(path, new_path)
    print(f"[fix] renamed {os.path.basename(path)} -> {os.path.basename(new_path)} (content is actually {kind})")
    return new_path


def find_disc_index(names):
    """Returns the first .gdi (preferred) or .cue entry name, or None."""
    gdi = [n for n in names if n.lower().endswith(".gdi")]
    if gdi:
        return gdi[0]
    cue = [n for n in names if n.lower().endswith(".cue")]
    if cue:
        return cue[0]
    return None


def convert_archive_to_chd(path, kind):
    name = os.path.basename(path)
    chd_path = os.path.splitext(path)[0] + ".chd"
    if os.path.exists(chd_path):
        print(f"[skip] {name}: {os.path.basename(chd_path)} already exists - not overwriting")
        return False

    print(f"[fix] {name}: converting archived multi-track GDI/CUE set to a single .chd "
          f"(Flycast can't load this format from inside an archive)")
    tmpdir = tempfile.mkdtemp(prefix="dcfix_", dir=os.path.dirname(path))
    try:
        subprocess.run(["7z", "x", "-y", f"-o{tmpdir}", path], check=True, capture_output=True)
        names = list_entries(path, kind)
        index_name = find_disc_index(names)
        if index_name is None:
            print(f"[skip] {name}: couldn't find the extracted .gdi/.cue on disk after extraction")
            return False
        index_path = os.path.join(tmpdir, index_name)
        if not os.path.isfile(index_path):
            print(f"[skip] {name}: expected extracted file '{index_name}' not found")
            return False

        tmp_chd = chd_path + ".new"
        if os.path.exists(tmp_chd):
            os.remove(tmp_chd)
        result = subprocess.run(
            ["chdman", "createcd", "-i", index_path, "-o", tmp_chd],
            capture_output=True, text=True,
        )
        if result.returncode != 0 or not os.path.exists(tmp_chd):
            print(f"[skip] {name}: chdman conversion failed:\\n{result.stdout[-500:]}\\n{result.stderr[-500:]}")
            if os.path.exists(tmp_chd):
                os.remove(tmp_chd)
            return False

        os.replace(tmp_chd, chd_path)
        os.remove(path)
        print(f"[fix] {name}: replaced with {os.path.basename(chd_path)}")
        return True
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    if not os.path.isdir(ROMS_DIR):
        print(f"{ROMS_DIR} does not exist, nothing to do")
        return
    if not have_chdman():
        print("chdman not found (should be installed from the mame-tools package) - "
              "can't convert any archived GDI/CUE sets to .chd, skipping")
        return

    fixed = 0
    for name in sorted(os.listdir(ROMS_DIR)):
        path = os.path.join(ROMS_DIR, name)
        if not os.path.isfile(path):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext not in (".zip", ".7z"):
            continue

        kind = real_archive_type(path)
        if kind is None:
            continue  # not actually a recognizable archive - leave it alone

        new_path = fix_extension(path, kind)
        if new_path is None:
            continue
        if new_path != path:
            fixed += 1
        path = new_path

        names = list_entries(path, kind)
        if not names:
            continue
        if find_disc_index(names) is None:
            continue  # no .gdi/.cue in here (e.g. a single .cdi/.chd) - already fine as-is

        if convert_archive_to_chd(path, kind):
            fixed += 1

    print(f"Done. {fixed} archive(s) fixed." if fixed else "Done. Nothing needed fixing.")


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    chmod +x "$PI_HOME/scripts/fix-dreamcast-roms.py"

    # Defensive/idempotent: harmless no-op on a fresh install (ROMs directory
    # is typically empty or nonexistent at this point), but also covers the
    # case of ROMs already being present (e.g. a connected-folder copy done
    # before this phase ran).
    python3 "$PI_HOME/scripts/fix-dreamcast-roms.py" || log_warn "fix-dreamcast-roms.py run failed - re-run it manually after adding Dreamcast ROMs"

    log "Flycast installed - copy dc_boot.bin and dc_flash.bin (dumped from your own Dreamcast) to $PI_HOME/RetroPie/BIOS/dc, and Dreamcast ROMs to $PI_HOME/RetroPie/roms/dreamcast (run ~/scripts/fix-dreamcast-roms.py afterward if any are zipped multi-track GDI/CUE dumps)"
    return 0
}

# Patches RetroArch's gl2 GL2 video driver so the RGUI menu/quick-menu is
# rotated to match the panel instead of always drawing unrotated (see the
# APPLY_RETROARCH_MENU_ROTATION_PATCH comment above for the full story).
# Modeled on _apply_quitmenu_patch's fail-soft pattern: matches exact,
# current-upstream anchor text and skips (with a warning, not a hard
# failure) if RetroArch's source has changed underneath it, rather than
# risking a corrupt/half-applied source tree.
_apply_retroarch_menu_rotation_patch() {
    local ra_src_dir="$1"
    python3 - "$ra_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
path = root / "gfx/drivers/gl2.c"
text = path.read_text()

old = """static INLINE void gl2_draw_texture(gl2_t *gl)
{
   GLfloat color[16];
   unsigned width         = gl->video_width;
   unsigned height        = gl->video_height;
"""

new = """static INLINE void gl2_draw_texture(gl2_t *gl)
{
   GLfloat color[16];
   /* The menu must always be oriented purely by the user's configured
    * video_rotation (physical panel-mounting compensation), never by
    * gl->rotation/gl->mvp - those reflect retroarch_get_rotation(), i.e.
    * config rotation PLUS whatever the active core has separately
    * requested via RETRO_ENVIRONMENT_SET_ROTATION (see runloop.c). Some
    * cores (confirmed: MAME, for ROT90 arcade games like Pac-Man) call
    * this, which overwrites gl->rotation with just their own raw request
    * (video_driver_set_rotation() passes it straight through, it does not
    * re-add the config value) - fine for game content, since MAME also
    * pre-rotates its own framebuffer pixels to compensate, but it leaves
    * the shared gl->mvp wrong for the menu texture specifically, which has
    * no such per-core compensation. Building a separate, config-only
    * rotation matrix here keeps the menu's orientation tied only to the
    * physical panel, regardless of what any given core requests. */
   math_matrix_4x4 menu_mvp;
   unsigned menu_rotation = config_get_ptr()->uints.video_rotation % 4;
   unsigned width         = gl->video_width;
   unsigned height        = gl->video_height;

   if (menu_rotation)
   {
      static math_matrix_4x4 menu_rot = {
         { 0.0f,     0.0f,    0.0f,    0.0f ,
           0.0f,     0.0f,    0.0f,    0.0f ,
           0.0f,     0.0f,    0.0f,    0.0f ,
           0.0f,     0.0f,    0.0f,    1.0f }
      };
      float radians = M_PI * (90.0f * menu_rotation) / 180.0f;
      float cosine   = cosf(radians);
      float sine     = sinf(radians);
      MAT_ELEM_4X4(menu_rot, 0, 0) = cosine;
      MAT_ELEM_4X4(menu_rot, 0, 1) = -sine;
      MAT_ELEM_4X4(menu_rot, 1, 0) = sine;
      MAT_ELEM_4X4(menu_rot, 1, 1) = cosine;
      matrix_4x4_multiply(menu_mvp, menu_rot, gl->mvp_no_rot);
   }
   else
      menu_mvp = gl->mvp_no_rot;
"""

old2 = "   gl->shader->set_mvp(gl->shader_data, &gl->mvp_no_rot);\n\n   glEnable(GL_BLEND);"
new2 = "   gl->shader->set_mvp(gl->shader_data, &menu_mvp);\n\n   glEnable(GL_BLEND);"

# gl2_render_overlay() - draws a RetroArch input_overlay (e.g. a Bezel
# Project bezel). Unlike the menu, an overlay frames actual game content,
# so it should rotate together with it - use gl->mvp (the same matrix
# content itself is drawn with, already reflecting video_rotation) instead
# of the hardcoded gl->mvp_no_rot upstream uses regardless of rotation.
old3 = "   gl->shader->set_coords(gl->shader_data, &gl->coords);\n   gl->shader->set_mvp(gl->shader_data, &gl->mvp_no_rot);\n\n   for (i = 0; i < gl->overlays; i++)"
new3 = "   gl->shader->set_coords(gl->shader_data, &gl->coords);\n   gl->shader->set_mvp(gl->shader_data, &gl->mvp);\n\n   for (i = 0; i < gl->overlays; i++)"

menu_ok = True
if new in text:
    print("[patch] gl2.c gl2_draw_texture: already applied")
elif text.count(old) != 1 or text.count(old2) != 1:
    print("[patch] gl2.c gl2_draw_texture: anchor text not found/not unique, skipping (RetroArch source may have changed) - menu will render unrotated, matching stock upstream behavior")
    menu_ok = False
else:
    text = text.replace(old, new, 1)
    text = text.replace(old2, new2, 1)
    print("[patch] gl2.c gl2_draw_texture: applied")

overlay_ok = True
if new3 in text:
    print("[patch] gl2.c gl2_render_overlay: already applied")
elif text.count(old3) != 1:
    print("[patch] gl2.c gl2_render_overlay: anchor text not found/not unique, skipping (RetroArch source may have changed) - overlay bezels will render unrotated, matching stock upstream behavior")
    overlay_ok = False
else:
    text = text.replace(old3, new3, 1)
    print("[patch] gl2.c gl2_render_overlay: applied")

path.write_text(text)
if not (menu_ok and overlay_ok):
    sys.exit(3)
PYEOF
}

# GameCube/Wii via Dolphin (lr-dolphin, the libretro port - exactly what
# ES-DE's own default gc/wii command expects, dolphin_libretro.so, so no
# alternativeEmulator override is needed once it's installed and symlinked
# by phase_esde_retroarch_links). ON BY DEFAULT SINCE THE USER ASKED FOR IT
# EXPLICITLY, but read this before relying on it: Dolphin on a Raspberry Pi
# 4 is well documented as poor for most titles even with heavy tuning -
# published benchmarks and community reports consistently show most
# GameCube games running somewhere in the 15-30fps range, with some 3D-
# heavy titles as low as 5-10fps, well below the original hardware's 60fps
# baseline; 2D-heavy or otherwise lightweight titles fare considerably
# better. The CPU/GPU overclock this project already applies by default
# (ENABLE_OVERCLOCK) is close to a requirement rather than a nice-to-have
# for even that level of performance, and getting the best result out of a
# given game typically needs real per-game tuning (OpenGL ES over Vulkan,
# resolution/scaling, DSP HLE vs LLE, etc.) beyond what this phase sets up.
# Set ENABLE_GAMECUBE=false to skip this entirely and keep the systems this
# hardware handles comfortably.
phase_gamecube_install() {
    if [ "$ENABLE_GAMECUBE" != "true" ]; then
        log "ENABLE_GAMECUBE=false, skipping"
        return 0
    fi
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    log "Installing Dolphin (GameCube/Wii) - trying a binary first, falling back to source if none exists for this platform"
    sudo ./retropie_packages.sh lr-dolphin _binary_
    if [ ! -f /opt/retropie/libretrocores/lr-dolphin/dolphin_libretro.so ]; then
        log_warn "lr-dolphin has no binary for this platform - falling back to a source build. Dolphin is a large codebase; this can take a long time on a Pi 4."
        sudo ./retropie_packages.sh lr-dolphin _source_ \
            || log_warn "lr-dolphin build failed - continuing without GameCube/Wii support, see the RetroPie-Setup build output above for the actual compiler error"
    fi

    if [ ! -f /opt/retropie/libretrocores/lr-dolphin/dolphin_libretro.so ]; then
        log_warn "dolphin_libretro.so not found after install; GameCube/Wii emulation will not be available"
        return 0
    fi

    mkdir -p "$PI_HOME/.config/retroarch/cores"
    ln -sf /opt/retropie/libretrocores/lr-dolphin/dolphin_libretro.so "$PI_HOME/.config/retroarch/cores/dolphin_libretro.so"
    mkdir -p "$PI_HOME/RetroPie/roms/gc" "$PI_HOME/RetroPie/roms/wii"
    log "Dolphin (GameCube/Wii) installed - see the README's Known limitations entry on realistic performance expectations for this hardware before spending time tuning individual games"
    return 0
}

# RetroPie-Setup's own basic_install builds RetroArch from source but leaves
# it unpatched. This re-patches the same source tree it already fetched
# (under RetroPie-Setup/tmp/build/retroarch) and re-runs just the
# build+install steps (RetroPie-Setup's own build_retroarch/install_retroarch
# functions - ./configure && make clean && make, then make install) rather
# than a full re-clone. Fails soft: if the source tree isn't where expected
# (e.g. a future RetroPie-Setup version changes its build layout) or the
# patch's anchor text doesn't match, this logs a warning and leaves the
# stock (unpatched, unrotated-menu) RetroArch in place instead of aborting
# the whole install.
phase_retroarch_menu_rotation_patch() {
    if [ "$APPLY_RETROARCH_MENU_ROTATION_PATCH" != "true" ]; then
        log "APPLY_RETROARCH_MENU_ROTATION_PATCH=false, skipping RetroArch menu rotation patch"
        return 0
    fi
    local ra_src_dir="$PI_HOME/RetroPie-Setup/tmp/build/retroarch"
    if [ ! -d "$ra_src_dir/gfx/drivers" ]; then
        log_warn "RetroArch source tree not found at $ra_src_dir (RetroPie-Setup layout may have changed) - skipping menu rotation patch, RGUI/quick-menu will render unrotated"
        return 0
    fi
    if ! _apply_retroarch_menu_rotation_patch "$ra_src_dir"; then
        log_warn "RetroArch menu rotation patch did not fully apply; RGUI/quick-menu will render unrotated (matching stock upstream behavior)"
        return 0
    fi
    log "Rebuilding RetroArch with the menu rotation patch (re-running RetroPie-Setup's own build+install steps)"
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    # Separate calls, not "retroarch build install" as one - confirmed live
    # (same root cause as the Flycast single-mode-dispatch finding
    # elsewhere in this file): rp_callModule() only ever acts on the
    # *first* mode argument given to it, so a combined call silently ran
    # "build" alone and never actually copied the freshly-built binary
    # into /opt/retropie/emulators/retroarch/bin/retroarch at all - every
    # prior run of this phase left the freshly-patched RetroArch sitting
    # uninstalled in the build tree while the *old* binary kept running,
    # with no error to indicate it.
    sudo ./retropie_packages.sh retroarch build || die "RetroArch rebuild after menu rotation patch failed"
    sudo ./retropie_packages.sh retroarch install || die "RetroArch install after menu rotation patch rebuild failed"

    if ! _apply_retroarch_quickmenu_extensions_patch "$ra_src_dir"; then
        log_warn "RetroArch Quick Menu extensions patch (Display Brightness/Sound/Game Audio) did not fully apply - continuing with whatever subset did apply, or none at all"
    else
        log "Rebuilding RetroArch again with the Quick Menu extensions (Display Brightness/Sound/Game Audio)"
        sudo ./retropie_packages.sh retroarch build || die "RetroArch rebuild after Quick Menu extensions patch failed"
        sudo ./retropie_packages.sh retroarch install || die "RetroArch install after Quick Menu extensions patch rebuild failed"
    fi
    return 0
}

# Extends RetroArch's own Quick Menu (opened in-game by the Home/Menu-
# Toggle hotkey; the same screen _apply_retroarch_menu_rotation_patch above
# already source-patches purely for rotation) with three new top-level
# entries - "Display Brightness", "Sound", and "Game Audio" - so every
# per-game hardware control this project offers lives in ONE place,
# reachable with just an arcade-style gamepad (Home button to open,
# D-pad/analog-stick Left-Right to adjust, B/Select to back out) - this
# replaces the old separate "Hotkey Config" L3+R3+face-button mechanism
# entirely (see that tool's own removal, and controller-hotkeys's removal,
# elsewhere in this script).
#
#   - Display Brightness: a single adjustable percentage entry. Reuses
#     RetroArch's OWN already-complete, already-working brightness
#     mechanism end-to-end (frontend_driver_set_screen_brightness(),
#     already wired to a real Settings-menu entry via
#     MENU_ENUM_LABEL_BRIGHTNESS_CONTROL) - the only RetroArch menu-code
#     change needed is ONE line pulling that existing setting into the
#     Quick Menu too, via MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM (the exact
#     same macro RetroArch itself uses to inject "State Slot" alongside
#     Save State/Load State in this same screen - confirmed live in
#     RetroArch's own source). Separately, this patch also fixes the unix
#     frontend driver's hardcoded "/sys/class/backlight/backlight/..."
#     path (confirmed not to exist on this hardware's touchscreen panel)
#     to auto-detect whatever backlight device sysfs actually exposes -
#     the same glob-first-match approach this project's own (now removed)
#     controller-hotkeys.py used for the same problem. Write permission
#     for the non-root RetroArch process is handled by a separate udev
#     rule - see phase_backlight_udev_permission.
#   - Sound: a new submenu (Output Device / Volume / Mute) driving the
#     system's actual PipeWire/WirePlumber audio output via wpctl - the
#     exact same commands this project's standalone "Audio settings" tool
#     already uses, ported here rather than reinvented, so both stay
#     consistent. This needs genuinely new menu code since it's OS-level
#     state RetroArch has no existing concept of: three small new
#     get_value/left/right dispatch cases (MENU_SETTING_ARCADE_SOUND_
#     DEVICE/VOLUME/MUTE), each adjustable with EITHER Left or Right
#     (toggling/stepping either direction) rather than needing a separate
#     confirm/select step - deliberately simple for a 4-button arcade
#     stick with no dedicated "confirm" affordance beyond one face button.
#   - Game Audio: a new submenu exposing the two MAME core options this
#     project registers (mame_arcade_audio_boost_db / mame_arcade_audio_
#     stereo - see _apply_mame_arcade_overlay_patch) as ordinary Quick
#     Menu entries, using RetroArch's OWN generic core-option rendering
#     (MENU_SETTINGS_CORE_OPTION_START + index - the exact same mechanism
#     "Core Options" itself uses internally) - zero new get/left/right
#     code needed for these two specific items, they are just looked up
#     by key and appended. Shows a placeholder message when the running
#     core isn't MAME (those two core options only exist for lr-mame).
#
# The two new top-level pushes ("Sound", "Game Audio") get their own small
# msg_hash_us.h string-table entries (unlike the earlier MAME-side patch,
# which deliberately avoided touching MAME's own string tables) - confirmed
# live in RetroArch's own source that its OK-callback binding table
# (menu_cbs_init_bind_ok_compare_label) matches Quick Menu push entries by
# comparing their *resolved display label string*, not their raw enum
# value as initially assumed; giving these two entries real, unique string
# entries (rather than relying on the "null" fallback every OTHER
# unregistered label enum also falls back to) is what makes that string
# comparison collision-free and deterministic.
#
# Same idempotent, anchor-checked, fail-soft pattern as every other source
# patch in this script.
_apply_retroarch_quickmenu_extensions_patch() {
    local ra_src_dir="$1"
    python3 - "$ra_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
overall_rc = [0]

def patch_file(relpath, replacements):
    path = root / relpath
    if not path.exists():
        print(f"[patch] {relpath}: file not found, skipping (RetroArch source may have changed)")
        overall_rc[0] = 3
        return
    text = path.read_text()
    changed = False
    for name, old, new in replacements:
        if new in text:
            print(f"[patch] {relpath} :: {name}: already applied")
            continue
        if old not in text:
            print(f"[patch] {relpath} :: {name}: anchor text not found, skipping (RetroArch source may have changed)")
            overall_rc[0] = 3
            continue
        text = text.replace(old, new, 1)
        changed = True
        print(f"[patch] {relpath} :: {name}: applied")
    if changed:
        path.write_text(text)

# -----------------------------------------------------------------------
# msg_hash.h: declare the two new label enums (LABEL/SUBLABEL/VALUE triple
# each, via the same MENU_LABEL() macro every other Quick Menu entry uses)
# -----------------------------------------------------------------------
patch_file("msg_hash.h", [
    ("declare QUICK_MENU_SOUND/GAME_AUDIO enums",
     "   MENU_LABEL(CORE_OPTIONS),\n",
     "   MENU_LABEL(CORE_OPTIONS),\n"
     "   MENU_LABEL(QUICK_MENU_SOUND),\n"
     "   MENU_LABEL(QUICK_MENU_GAME_AUDIO),\n"),
])

# -----------------------------------------------------------------------
# intl/msg_hash_us.h: English strings for those two labels (LABEL bare +
# SUBLABEL + VALUE) - the bare LABEL string specifically is what makes
# menu_cbs_init_bind_ok_compare_label's string match collision-free (see
# this function's own top comment).
# -----------------------------------------------------------------------
patch_file("intl/msg_hash_us.h", [
    ("QUICK_MENU_SOUND/GAME_AUDIO strings",
     'MSG_HASH(\n'
     '   MENU_ENUM_SUBLABEL_CORE_OPTIONS,\n'
     '   "Change the options for the currently running content."\n'
     '   )\n',
     'MSG_HASH(\n'
     '   MENU_ENUM_SUBLABEL_CORE_OPTIONS,\n'
     '   "Change the options for the currently running content."\n'
     '   )\n'
     'MSG_HASH(\n'
     '   MENU_ENUM_LABEL_QUICK_MENU_SOUND,\n'
     '   "quick_menu_sound"\n'
     '   )\n'
     'MSG_HASH(\n'
     '   MENU_ENUM_LABEL_VALUE_QUICK_MENU_SOUND,\n'
     '   "Sound"\n'
     '   )\n'
     'MSG_HASH(\n'
     '   MENU_ENUM_SUBLABEL_QUICK_MENU_SOUND,\n'
     '   "Configure the system audio output device, volume, and mute (via WirePlumber/PipeWire)."\n'
     '   )\n'
     'MSG_HASH(\n'
     '   MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO,\n'
     '   "quick_menu_game_audio"\n'
     '   )\n'
     'MSG_HASH(\n'
     '   MENU_ENUM_LABEL_VALUE_QUICK_MENU_GAME_AUDIO,\n'
     '   "Game Audio"\n'
     '   )\n'
     'MSG_HASH(\n'
     '   MENU_ENUM_SUBLABEL_QUICK_MENU_GAME_AUDIO,\n'
     '   "Per-game arcade audio boost and stereo/mono downmix (MAME only)."\n'
     '   )\n'),
])

# -----------------------------------------------------------------------
# menu/menu_driver.h: three new leaf item "type" constants for the Sound
# screen (Display Brightness and Game Audio need no new type constants -
# see this patch's own top comment).
# -----------------------------------------------------------------------
patch_file("menu/menu_driver.h", [
    ("MENU_SETTING_ARCADE_SOUND_* constants",
     "   MENU_SETTING_ACTION_CONTENTLESS_CORE_RUN,\n\n   MENU_SETTINGS_LAST\n};",
     "   MENU_SETTING_ACTION_CONTENTLESS_CORE_RUN,\n\n"
     "   MENU_SETTING_ARCADE_SOUND_DEVICE,\n"
     "   MENU_SETTING_ARCADE_SOUND_VOLUME,\n"
     "   MENU_SETTING_ARCADE_SOUND_MUTE,\n\n"
     "   MENU_SETTINGS_LAST\n};"),
])

# -----------------------------------------------------------------------
# menu/menu_displaylist.h: two new displaylist screen types (Sound,
# Game Audio submenus).
# -----------------------------------------------------------------------
patch_file("menu/menu_displaylist.h", [
    ("DISPLAYLIST_PI_ARCADE_* constants",
     "   DISPLAYLIST_PENDING_CLEAR,\n"
     "   DISPLAYLIST_SHADER_PRESET_PREPEND,\n"
     "   DISPLAYLIST_SHADER_PRESET_APPEND\n};",
     "   DISPLAYLIST_PENDING_CLEAR,\n"
     "   DISPLAYLIST_SHADER_PRESET_PREPEND,\n"
     "   DISPLAYLIST_SHADER_PRESET_APPEND,\n"
     "   DISPLAYLIST_PI_ARCADE_SOUND,\n"
     "   DISPLAYLIST_PI_ARCADE_GAME_AUDIO\n};"),
])

# -----------------------------------------------------------------------
# menu/menu_cbs.h: two new OK-push action types for those two screens.
# -----------------------------------------------------------------------
patch_file("menu/menu_cbs.h", [
    ("ACTION_OK_DL_PI_ARCADE_* constants",
     "   ACTION_OK_DL_REMAP_FILE_MANAGER_LIST,\n   ACTION_OK_DL_ADD_TO_PLAYLIST\n};",
     "   ACTION_OK_DL_REMAP_FILE_MANAGER_LIST,\n"
     "   ACTION_OK_DL_ADD_TO_PLAYLIST,\n"
     "   ACTION_OK_DL_PI_ARCADE_SOUND,\n"
     "   ACTION_OK_DL_PI_ARCADE_GAME_AUDIO\n};"),
])

# -----------------------------------------------------------------------
# menu/cbs/menu_cbs_ok.c: the two new pushes' OK-callback wiring, modeled
# directly on ACTION_OK_DL_CONTENT_SETTINGS (a "push a new self-built
# list" pattern already used throughout this same function).
# -----------------------------------------------------------------------
patch_file("menu/cbs/menu_cbs_ok.c", [
    ("action_ok_push_pi_arcade_* declarations",
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_push_core_options_list, ACTION_OK_DL_CORE_OPTIONS_LIST)\n",
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_push_core_options_list, ACTION_OK_DL_CORE_OPTIONS_LIST)\n"
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_push_pi_arcade_sound, ACTION_OK_DL_PI_ARCADE_SOUND)\n"
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_push_pi_arcade_game_audio, ACTION_OK_DL_PI_ARCADE_GAME_AUDIO)\n"),
    ("generic_action_ok_displaylist_push switch cases",
     "      case ACTION_OK_DL_CONTENT_SETTINGS:\n"
     "         info.list          = MENU_LIST_GET_SELECTION(menu_list, 0);\n"
     "         info_path          = msg_hash_to_str(MENU_ENUM_LABEL_VALUE_CONTENT_SETTINGS);\n"
     "         info_label         = msg_hash_to_str(MENU_ENUM_LABEL_CONTENT_SETTINGS);\n"
     "         info.enum_idx      = MENU_ENUM_LABEL_CONTENT_SETTINGS;\n"
     "         menu_entries_append(menu_stack, info_path, info_label,\n"
     "               MENU_ENUM_LABEL_CONTENT_SETTINGS,\n"
     "               0, 0, 0, NULL);\n"
     "         dl_type            = DISPLAYLIST_CONTENT_SETTINGS;\n"
     "         break;\n"
     "   }",
     "      case ACTION_OK_DL_CONTENT_SETTINGS:\n"
     "         info.list          = MENU_LIST_GET_SELECTION(menu_list, 0);\n"
     "         info_path          = msg_hash_to_str(MENU_ENUM_LABEL_VALUE_CONTENT_SETTINGS);\n"
     "         info_label         = msg_hash_to_str(MENU_ENUM_LABEL_CONTENT_SETTINGS);\n"
     "         info.enum_idx      = MENU_ENUM_LABEL_CONTENT_SETTINGS;\n"
     "         menu_entries_append(menu_stack, info_path, info_label,\n"
     "               MENU_ENUM_LABEL_CONTENT_SETTINGS,\n"
     "               0, 0, 0, NULL);\n"
     "         dl_type            = DISPLAYLIST_CONTENT_SETTINGS;\n"
     "         break;\n"
     "      case ACTION_OK_DL_PI_ARCADE_SOUND:\n"
     "         info.list          = MENU_LIST_GET_SELECTION(menu_list, 0);\n"
     "         info_path          = msg_hash_to_str(MENU_ENUM_LABEL_VALUE_QUICK_MENU_SOUND);\n"
     "         info_label         = msg_hash_to_str(MENU_ENUM_LABEL_QUICK_MENU_SOUND);\n"
     "         info.enum_idx      = MENU_ENUM_LABEL_QUICK_MENU_SOUND;\n"
     "         menu_entries_append(menu_stack, info_path, info_label,\n"
     "               MENU_ENUM_LABEL_QUICK_MENU_SOUND,\n"
     "               0, 0, 0, NULL);\n"
     "         dl_type            = DISPLAYLIST_PI_ARCADE_SOUND;\n"
     "         break;\n"
     "      case ACTION_OK_DL_PI_ARCADE_GAME_AUDIO:\n"
     "         info.list          = MENU_LIST_GET_SELECTION(menu_list, 0);\n"
     "         info_path          = msg_hash_to_str(MENU_ENUM_LABEL_VALUE_QUICK_MENU_GAME_AUDIO);\n"
     "         info_label         = msg_hash_to_str(MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO);\n"
     "         info.enum_idx      = MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO;\n"
     "         menu_entries_append(menu_stack, info_path, info_label,\n"
     "               MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO,\n"
     "               0, 0, 0, NULL);\n"
     "         dl_type            = DISPLAYLIST_PI_ARCADE_GAME_AUDIO;\n"
     "         break;\n"
     "   }"),
    ("ok_list[] table entries (string-compare fallback array - kept for\n"
     "     safety/consistency, though the real fix is the enum-compare array\n"
     "     below, since our entries always have a real enum_idx)",
     "         {MENU_ENUM_LABEL_MANUAL_CONTENT_SCAN_DAT_FILE,        action_ok_manual_content_scan_dat_file},\n"
     "      };\n"
     "\n"
     "      for (i = 0; i < ARRAY_SIZE(ok_list); i++)\n"
     "      {\n"
     "         if (string_is_equal(label, msg_hash_to_str(ok_list[i].type)))",
     "         {MENU_ENUM_LABEL_MANUAL_CONTENT_SCAN_DAT_FILE,        action_ok_manual_content_scan_dat_file},\n"
     "         {MENU_ENUM_LABEL_QUICK_MENU_SOUND,                    action_ok_push_pi_arcade_sound},\n"
     "         {MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO,               action_ok_push_pi_arcade_game_audio},\n"
     "      };\n"
     "\n"
     "      for (i = 0; i < ARRAY_SIZE(ok_list); i++)\n"
     "      {\n"
     "         if (string_is_equal(label, msg_hash_to_str(ok_list[i].type)))"),
    # BUG FOUND LIVE (disclosed per the user's request to note and fix any
    # errors along the way): pressing OK/A on "Sound" or "Game Audio" did
    # nothing at all. Root-caused via a live gdb-free strace of RetroArch's
    # own stderr (temporary debug fprintf calls, since removed) which
    # showed menu_cbs_init_bind_ok_compare_label() reaching its *string*-
    # keyed ok_list[] scan (the one patched just above) and NOT matching -
    # because that string-keyed array is only ever consulted in the
    # `else` branch of `if (cbs->enum_idx != MSG_UNKNOWN) { ...enum-keyed
    # ok_list...} else { ...string-keyed ok_list... }`. Since our two new
    # entries DO have a real enum_idx (MENU_ENUM_LABEL_QUICK_MENU_SOUND/
    # GAME_AUDIO, passed to menu_entries_append), they always take the
    # *first* (enum-keyed, `cbs->enum_idx == ok_list[i].type`) branch,
    # where they were never registered - the string-keyed addition above
    # was therefore dead code for these two entries. Fixed by also
    # registering them in the enum-keyed array, which is the one that
    # actually gets consulted.
    ("ok_list[] table entries (enum-compare array - this is the one that\n"
     "     actually runs for entries with a real enum_idx, which ours have)",
     "         {MENU_ENUM_LABEL_CONTENTLESS_CORES_TAB,               action_ok_push_default},\n"
     "      };\n"
     "\n"
     "      for (i = 0; i < ARRAY_SIZE(ok_list); i++)\n"
     "      {\n"
     "         if (cbs->enum_idx == ok_list[i].type)",
     "         {MENU_ENUM_LABEL_CONTENTLESS_CORES_TAB,               action_ok_push_default},\n"
     "         {MENU_ENUM_LABEL_QUICK_MENU_SOUND,                    action_ok_push_pi_arcade_sound},\n"
     "         {MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO,               action_ok_push_pi_arcade_game_audio},\n"
     "      };\n"
     "\n"
     "      for (i = 0; i < ARRAY_SIZE(ok_list); i++)\n"
     "      {\n"
     "         if (cbs->enum_idx == ok_list[i].type)"),
])

sys.exit(overall_rc[0])
PYEOF
    local status=$?

    _apply_retroarch_pi_arcade_sound_header "$ra_src_dir" || status=3
    _apply_retroarch_left_right_get_value_patch "$ra_src_dir" || status=3
    _apply_retroarch_displaylist_content_patch "$ra_src_dir" || status=3
    _apply_retroarch_backlight_path_patch "$ra_src_dir" || status=3
    _apply_retroarch_brightness_wraparound_patch "$ra_src_dir" || status=3

    return $status
}

# Small header-only declaration file for the wpctl-backed Sound helpers -
# implemented (non-static, so every translation unit below can link
# against them) directly inside menu_displaylist.c by
# _apply_retroarch_displaylist_content_patch, rather than registering a
# brand new .c file with RetroArch's own Makefile.common (lower risk: no
# build-system changes needed at all, just an extra header include in
# three already-compiled files).
_apply_retroarch_pi_arcade_sound_header() {
    local ra_src_dir="$1"
    local header="$ra_src_dir/menu/pi_arcade_sound.h"
    if [ -f "$header" ] && grep -q "pi_arcade_sound_get_device" "$header"; then
        echo "[patch] menu/pi_arcade_sound.h: already applied"
        return 0
    fi
    cat > "$header" <<'HEOF'
/* pi-arcade-setup: system audio output control (device/volume/mute) for
 * the RetroArch Quick Menu's "Sound" entry, via wpctl (PipeWire/
 * WirePlumber) - the same tool this project's standalone "Audio settings"
 * RetroPie-menu tool already uses, kept consistent rather than reinvented.
 * Implemented in menu_displaylist.c; declared here so menu_cbs_left.c,
 * menu_cbs_right.c, and menu_cbs_get_value.c can all link against the
 * same implementation without RetroArch's build needing a new source
 * file registered. */

#ifndef PI_ARCADE_SOUND_H
#define PI_ARCADE_SOUND_H

#include <retro_common_api.h>

RETRO_BEGIN_DECLS

/* 0 = aux/headphone jack, 1 = HDMI, -1 = unknown/no matching sink found */
int pi_arcade_sound_get_device(void);
/* dev: 0 or 1 as above. No-op if that kind of sink isn't present. */
void pi_arcade_sound_set_device(int dev);

/* 0-100, or -1 if unavailable */
int pi_arcade_sound_get_volume(void);
/* delta_percent: e.g. +5 or -5 */
void pi_arcade_sound_adjust_volume(int delta_percent);

/* 1 = muted, 0 = unmuted, -1 = unknown */
int pi_arcade_sound_get_mute(void);
void pi_arcade_sound_toggle_mute(void);

RETRO_END_DECLS

#endif
HEOF
    echo "[patch] menu/pi_arcade_sound.h: applied (new file)"
    return 0
}

# Wires the Sound screen's three leaf items (Output Device, Volume, Mute)
# into menu_cbs_left.c/menu_cbs_right.c (adjustment - deliberately bound to
# BOTH directions identically for the two binary items, so either Left or
# Right on a 2-axis d-pad toggles them - simplest for a bare-bones arcade
# stick) and menu_cbs_get_value.c (display text). Modeled directly on the
# existing MENU_SETTINGS_CORE_DISK_OPTIONS_DISK_INDEX single-item pattern
# already present in both left.c and right.c.
_apply_retroarch_left_right_get_value_patch() {
    local ra_src_dir="$1"
    python3 - "$ra_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
overall_rc = [0]

def patch_file(relpath, replacements):
    path = root / relpath
    if not path.exists():
        print(f"[patch] {relpath}: file not found, skipping (RetroArch source may have changed)")
        overall_rc[0] = 3
        return
    text = path.read_text()
    changed = False
    for name, old, new in replacements:
        if new in text:
            print(f"[patch] {relpath} :: {name}: already applied")
            continue
        if old not in text:
            print(f"[patch] {relpath} :: {name}: anchor text not found, skipping (RetroArch source may have changed)")
            overall_rc[0] = 3
            continue
        text = text.replace(old, new, 1)
        changed = True
        print(f"[patch] {relpath} :: {name}: applied")
    if changed:
        path.write_text(text)

patch_file("menu/cbs/menu_cbs_left.c", [
    ("include pi_arcade_sound.h",
     '#include "../menu_setting.h"\n',
     '#include "../menu_setting.h"\n#include "../pi_arcade_sound.h"\n'),
    ("pi_arcade_sound_setting_left function",
     "static int core_setting_left(unsigned type, const char *label,\n"
     "      bool wraparound)\n"
     "{\n"
     "   unsigned idx     = type - MENU_SETTINGS_CORE_OPTION_START;\n"
     "\n"
     "   retroarch_ctl(RARCH_CTL_CORE_OPTION_PREV, &idx);\n"
     "\n"
     "   return 0;\n"
     "}\n",
     "static int pi_arcade_sound_setting_left(unsigned type, const char *label,\n"
     "      bool wraparound)\n"
     "{\n"
     "   switch (type)\n"
     "   {\n"
     "      case MENU_SETTING_ARCADE_SOUND_DEVICE:\n"
     "         pi_arcade_sound_set_device(pi_arcade_sound_get_device() == 1 ? 0 : 1);\n"
     "         break;\n"
     "      case MENU_SETTING_ARCADE_SOUND_VOLUME:\n"
     "         pi_arcade_sound_adjust_volume(-5);\n"
     "         break;\n"
     "      case MENU_SETTING_ARCADE_SOUND_MUTE:\n"
     "         pi_arcade_sound_toggle_mute();\n"
     "         break;\n"
     "      default:\n"
     "         break;\n"
     "   }\n"
     "\n"
     "   return 0;\n"
     "}\n"
     "\n"
     "static int core_setting_left(unsigned type, const char *label,\n"
     "      bool wraparound)\n"
     "{\n"
     "   unsigned idx     = type - MENU_SETTINGS_CORE_OPTION_START;\n"
     "\n"
     "   retroarch_ctl(RARCH_CTL_CORE_OPTION_PREV, &idx);\n"
     "\n"
     "   return 0;\n"
     "}\n"),
    ("dispatch case for MENU_SETTING_ARCADE_SOUND_*",
     "      switch (type)\n"
     "      {\n"
     "         case MENU_SETTINGS_CORE_DISK_OPTIONS_DISK_INDEX:\n"
     "            BIND_ACTION_LEFT(cbs, disk_options_disk_idx_left);\n"
     "            break;\n",
     "      switch (type)\n"
     "      {\n"
     "         case MENU_SETTING_ARCADE_SOUND_DEVICE:\n"
     "         case MENU_SETTING_ARCADE_SOUND_VOLUME:\n"
     "         case MENU_SETTING_ARCADE_SOUND_MUTE:\n"
     "            BIND_ACTION_LEFT(cbs, pi_arcade_sound_setting_left);\n"
     "            break;\n"
     "         case MENU_SETTINGS_CORE_DISK_OPTIONS_DISK_INDEX:\n"
     "            BIND_ACTION_LEFT(cbs, disk_options_disk_idx_left);\n"
     "            break;\n"),
])

patch_file("menu/cbs/menu_cbs_right.c", [
    ("include pi_arcade_sound.h",
     '#include "../menu_setting.h"\n',
     '#include "../menu_setting.h"\n#include "../pi_arcade_sound.h"\n'),
    ("pi_arcade_sound_setting_right function",
     "static int core_setting_right(unsigned type, const char *label,\n"
     "      bool wraparound)\n"
     "{\n"
     "   unsigned idx     = type - MENU_SETTINGS_CORE_OPTION_START;\n"
     "\n"
     "   retroarch_ctl(RARCH_CTL_CORE_OPTION_NEXT, &idx);\n"
     "\n"
     "   return 0;\n"
     "}\n",
     "static int pi_arcade_sound_setting_right(unsigned type, const char *label,\n"
     "      bool wraparound)\n"
     "{\n"
     "   switch (type)\n"
     "   {\n"
     "      case MENU_SETTING_ARCADE_SOUND_DEVICE:\n"
     "         pi_arcade_sound_set_device(pi_arcade_sound_get_device() == 1 ? 0 : 1);\n"
     "         break;\n"
     "      case MENU_SETTING_ARCADE_SOUND_VOLUME:\n"
     "         pi_arcade_sound_adjust_volume(5);\n"
     "         break;\n"
     "      case MENU_SETTING_ARCADE_SOUND_MUTE:\n"
     "         pi_arcade_sound_toggle_mute();\n"
     "         break;\n"
     "      default:\n"
     "         break;\n"
     "   }\n"
     "\n"
     "   return 0;\n"
     "}\n"
     "\n"
     "static int core_setting_right(unsigned type, const char *label,\n"
     "      bool wraparound)\n"
     "{\n"
     "   unsigned idx     = type - MENU_SETTINGS_CORE_OPTION_START;\n"
     "\n"
     "   retroarch_ctl(RARCH_CTL_CORE_OPTION_NEXT, &idx);\n"
     "\n"
     "   return 0;\n"
     "}\n"),
    ("dispatch case for MENU_SETTING_ARCADE_SOUND_*",
     "      switch (type)\n"
     "      {\n"
     "         case MENU_SETTINGS_CORE_DISK_OPTIONS_DISK_INDEX:\n"
     "            BIND_ACTION_RIGHT(cbs, disk_options_disk_idx_right);\n"
     "            break;\n",
     "      switch (type)\n"
     "      {\n"
     "         case MENU_SETTING_ARCADE_SOUND_DEVICE:\n"
     "         case MENU_SETTING_ARCADE_SOUND_VOLUME:\n"
     "         case MENU_SETTING_ARCADE_SOUND_MUTE:\n"
     "            BIND_ACTION_RIGHT(cbs, pi_arcade_sound_setting_right);\n"
     "            break;\n"
     "         case MENU_SETTINGS_CORE_DISK_OPTIONS_DISK_INDEX:\n"
     "            BIND_ACTION_RIGHT(cbs, disk_options_disk_idx_right);\n"
     "            break;\n"),
])

patch_file("menu/cbs/menu_cbs_get_value.c", [
    ("include pi_arcade_sound.h",
     '#include "../menu_cbs.h"\n',
     '#include "../menu_cbs.h"\n#include "../pi_arcade_sound.h"\n'),
    ("pi_arcade_sound_get_value function",
     "static void menu_action_setting_disp_set_label_core_option(\n",
     "static void pi_arcade_sound_get_value(\n"
     "      file_list_t* list,\n"
     "      unsigned *w, unsigned type, unsigned i,\n"
     "      const char *label,\n"
     "      char *s, size_t len,\n"
     "      const char *path,\n"
     "      char *s2, size_t len2)\n"
     "{\n"
     "   *w  = 19;\n"
     "   *s  = '\\0';\n"
     "   *s2 = '\\0';\n"
     "\n"
     "   switch (type)\n"
     "   {\n"
     "      case MENU_SETTING_ARCADE_SOUND_DEVICE:\n"
     "         {\n"
     "            int dev = pi_arcade_sound_get_device();\n"
     "            if (dev == 1)\n"
     "               strlcpy(s, \"HDMI\", len);\n"
     "            else if (dev == 0)\n"
     "               strlcpy(s, \"Aux / Headphone jack\", len);\n"
     "            else\n"
     "               strlcpy(s, \"Unknown\", len);\n"
     "         }\n"
     "         break;\n"
     "      case MENU_SETTING_ARCADE_SOUND_VOLUME:\n"
     "         {\n"
     "            int vol = pi_arcade_sound_get_volume();\n"
     "            if (vol < 0)\n"
     "               strlcpy(s, \"N/A\", len);\n"
     "            else\n"
     "               snprintf(s, len, \"%d%%\", vol);\n"
     "         }\n"
     "         break;\n"
     "      case MENU_SETTING_ARCADE_SOUND_MUTE:\n"
     "         {\n"
     "            int m = pi_arcade_sound_get_mute();\n"
     "            if (m == 1)\n"
     "               strlcpy(s, \"Muted\", len);\n"
     "            else if (m == 0)\n"
     "               strlcpy(s, \"Unmuted\", len);\n"
     "            else\n"
     "               strlcpy(s, \"Unknown\", len);\n"
     "         }\n"
     "         break;\n"
     "      default:\n"
     "         break;\n"
     "   }\n"
     "}\n"
     "\n"
     "static void menu_action_setting_disp_set_label_core_option(\n"),
    ("dispatch for MENU_SETTING_ARCADE_SOUND_* in get_value",
     "   if ((type >= MENU_SETTINGS_CORE_OPTION_START) &&\n"
     "       (type < MENU_SETTINGS_CHEEVOS_START))\n"
     "   {\n"
     "      BIND_ACTION_GET_VALUE(cbs,\n"
     "         menu_action_setting_disp_set_label_core_option);\n"
     "      return 0;\n"
     "   }\n",
     "   if (type == MENU_SETTING_ARCADE_SOUND_DEVICE ||\n"
     "       type == MENU_SETTING_ARCADE_SOUND_VOLUME ||\n"
     "       type == MENU_SETTING_ARCADE_SOUND_MUTE)\n"
     "   {\n"
     "      BIND_ACTION_GET_VALUE(cbs, pi_arcade_sound_get_value);\n"
     "      return 0;\n"
     "   }\n"
     "\n"
     "   if ((type >= MENU_SETTINGS_CORE_OPTION_START) &&\n"
     "       (type < MENU_SETTINGS_CHEEVOS_START))\n"
     "   {\n"
     "      BIND_ACTION_GET_VALUE(cbs,\n"
     "         menu_action_setting_disp_set_label_core_option);\n"
     "      return 0;\n"
     "   }\n"),
])

sys.exit(overall_rc[0])
PYEOF
    return $?
}

# The big one: implements the wpctl-backed Sound helpers (non-static, per
# menu/pi_arcade_sound.h above), the two new screens' content-builder
# functions, and wires everything into menu_displaylist.c's two dispatch
# points (menu_displaylist_build_list()'s per-type switch, and
# menu_displaylist_ctl()'s big shared "clear + rebuild" case group used by
# every simple self-built list screen) plus the three new top-level Quick
# Menu pushes (Display Brightness/Sound/Game Audio) into
# menu_displaylist_parse_load_content_settings(), right after the existing
# "Core Options" push.
_apply_retroarch_displaylist_content_patch() {
    local ra_src_dir="$1"
    python3 - "$ra_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
overall_rc = [0]

def patch_file(relpath, replacements):
    path = root / relpath
    if not path.exists():
        print(f"[patch] {relpath}: file not found, skipping (RetroArch source may have changed)")
        overall_rc[0] = 3
        return
    text = path.read_text()
    changed = False
    for name, old, new in replacements:
        if new in text:
            print(f"[patch] {relpath} :: {name}: already applied")
            continue
        if old not in text:
            print(f"[patch] {relpath} :: {name}: anchor text not found, skipping (RetroArch source may have changed)")
            overall_rc[0] = 3
            continue
        text = text.replace(old, new, 1)
        changed = True
        print(f"[patch] {relpath} :: {name}: applied")
    if changed:
        path.write_text(text)

helper_impl = '''/* pi-arcade-setup: wpctl (PipeWire/WirePlumber) helpers backing the Quick
 * Menu's "Sound" entry - see menu/pi_arcade_sound.h. Ported from this
 * project's own standalone "Audio settings" RetroPie-menu tool
 * (audio-settings.py) rather than reinvented, so both stay consistent. */

static bool pi_arcade_run_capture(const char *cmd, char *out, size_t out_len)
{
   FILE *fp;
   size_t n;

   if (!cmd || !out || out_len == 0)
      return false;

   fp = popen(cmd, "r");
   if (!fp)
      return false;

   n = fread(out, 1, out_len - 1, fp);
   out[n] = '\\0';
   pclose(fp);
   return true;
}

/* Scans a `wpctl status` capture for the Sinks: section and finds the id
 * of the first sink whose status line (or, failing that, its `wpctl
 * inspect <id>` output) contains any of the given keywords. */
static bool pi_arcade_find_sink_id_by_keywords(
      const char *status_text, const char *const *keywords, size_t n_keywords,
      int *id_out, bool *is_default_out)
{
   const char *line = status_text;
   bool in_sinks = false;

   if (!status_text)
      return false;

   while (line && *line)
   {
      const char *next     = strchr(line, '\\n');
      size_t line_len      = next ? (size_t)(next - line) : strlen(line);
      char buf[512];
      size_t copy_len      = (line_len < sizeof(buf) - 1) ? line_len : sizeof(buf) - 1;

      memcpy(buf, line, copy_len);
      buf[copy_len] = '\\0';

      if (strstr(buf, "Sinks:"))
         in_sinks = true;
      else if (in_sinks && (strstr(buf, "Sources:") || strstr(buf, "Filters:") || strstr(buf, "Streams:")))
         in_sinks = false;
      else if (in_sinks)
      {
         const char *dotpos = strchr(buf, '.');
         if (dotpos)
         {
            const char *p = buf;
            while (*p && !isdigit((unsigned char)*p))
               p++;
            if (p < dotpos && isdigit((unsigned char)*p))
            {
               int id       = atoi(p);
               bool matched = false;
               size_t k;

               for (k = 0; k < n_keywords && !matched; k++)
                  if (strstr(buf, keywords[k]))
                     matched = true;

               if (!matched)
               {
                  char inspect_cmd[128];
                  char inspect_out[8192];

                  snprintf(inspect_cmd, sizeof(inspect_cmd), "wpctl inspect %d 2>/dev/null", id);
                  if (pi_arcade_run_capture(inspect_cmd, inspect_out, sizeof(inspect_out)))
                     for (k = 0; k < n_keywords && !matched; k++)
                        if (strstr(inspect_out, keywords[k]))
                           matched = true;
               }

               if (matched)
               {
                  if (id_out)
                     *id_out = id;
                  if (is_default_out)
                     *is_default_out = (strchr(buf, '*') != NULL);
                  return true;
               }
            }
         }
      }

      line = next ? next + 1 : NULL;
   }

   return false;
}

static const char *const pi_arcade_aux_keywords[]  = { "mailbox", "bcm2835 Headphones", "Headphones" };
static const char *const pi_arcade_hdmi_keywords[]  = { "hdmi", "HDMI", "vc4-hdmi" };

int pi_arcade_sound_get_device(void)
{
   char status[8192];
   int id;
   bool is_default;

   if (!pi_arcade_run_capture("wpctl status 2>/dev/null", status, sizeof(status)))
      return -1;

   if (pi_arcade_find_sink_id_by_keywords(status, pi_arcade_hdmi_keywords, 3, &id, &is_default) && is_default)
      return 1;
   if (pi_arcade_find_sink_id_by_keywords(status, pi_arcade_aux_keywords, 3, &id, &is_default) && is_default)
      return 0;

   return -1;
}

void pi_arcade_sound_set_device(int dev)
{
   char status[8192];
   int id;
   char cmd[64];

   if (!pi_arcade_run_capture("wpctl status 2>/dev/null", status, sizeof(status)))
      return;

   if (dev == 1)
   {
      if (pi_arcade_find_sink_id_by_keywords(status, pi_arcade_hdmi_keywords, 3, &id, NULL))
      {
         snprintf(cmd, sizeof(cmd), "wpctl set-default %d", id);
         system(cmd);
      }
   }
   else
   {
      if (pi_arcade_find_sink_id_by_keywords(status, pi_arcade_aux_keywords, 3, &id, NULL))
      {
         snprintf(cmd, sizeof(cmd), "wpctl set-default %d", id);
         system(cmd);
      }
   }
}

int pi_arcade_sound_get_volume(void)
{
   char out[512];
   const char *p;

   if (!pi_arcade_run_capture("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", out, sizeof(out)))
      return -1;

   p = strstr(out, "Volume:");
   if (!p)
      return -1;
   p += strlen("Volume:");
   while (*p == ' ')
      p++;

   return (int)(atof(p) * 100.0 + 0.5);
}

int pi_arcade_sound_get_mute(void)
{
   char out[512];

   if (!pi_arcade_run_capture("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null", out, sizeof(out)))
      return -1;

   return strstr(out, "[MUTED]") ? 1 : 0;
}

void pi_arcade_sound_adjust_volume(int delta_percent)
{
   char cmd[96];

   snprintf(cmd, sizeof(cmd), "wpctl set-volume @DEFAULT_AUDIO_SINK@ %d%%%s",
         delta_percent < 0 ? -delta_percent : delta_percent,
         delta_percent < 0 ? "-" : "+");
   system(cmd);
}

void pi_arcade_sound_toggle_mute(void)
{
   system("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
}

/* -----------------------------------------------------------------------
 * Content-builders for the two new Quick Menu screens.
 * ----------------------------------------------------------------------- */

static unsigned menu_displaylist_parse_pi_arcade_sound(file_list_t *list)
{
   unsigned count = 0;

   /* pi-arcade-setup: enum_idx must be MSG_UNKNOWN (not MENU_ENUM_LABEL_NO_ITEMS)
    * here. menu_cbs_init_bind_left/_right_compare_label() has an explicit
    * `case MENU_ENUM_LABEL_NO_ITEMS:` that binds action_left/right_scroll and
    * returns 0 whenever cbs->enum_idx matches it - which happens BEFORE
    * compare_type() (where our MENU_SETTING_ARCADE_SOUND_* switch case lives)
    * ever runs, silently eating all Left/Right input on these rows. Using
    * MSG_UNKNOWN makes `cbs->enum_idx != MSG_UNKNOWN` false so compare_label
    * takes its early `return -1;`, and compare_type runs as intended. */
   if (menu_entries_append(list,
            "Output Device", "",
            MSG_UNKNOWN, MENU_SETTING_ARCADE_SOUND_DEVICE,
            0, 0, NULL))
      count++;

   if (menu_entries_append(list,
            "Volume", "",
            MSG_UNKNOWN, MENU_SETTING_ARCADE_SOUND_VOLUME,
            0, 0, NULL))
      count++;

   if (menu_entries_append(list,
            "Mute", "",
            MSG_UNKNOWN, MENU_SETTING_ARCADE_SOUND_MUTE,
            0, 0, NULL))
      count++;

   return count;
}

static unsigned menu_displaylist_parse_pi_arcade_game_audio(file_list_t *list)
{
   unsigned count                  = 0;
   core_option_manager_t *coreopts = NULL;

   if (retroarch_ctl(RARCH_CTL_CORE_OPTIONS_LIST_GET, &coreopts) && coreopts)
   {
      size_t idx;

      /* pi-arcade-setup: use MENU_ENUM_LABEL_CORE_OPTION_ENTRY here, matching
       * how stock RetroArch itself appends MENU_SETTINGS_CORE_OPTION_START-
       * range entries elsewhere (see the main core-options displaylist
       * builder). That enum has no case in
       * menu_cbs_init_bind_left/_right_compare_label()'s switch, so it falls
       * through to compare_label's `default: return -1;` and lets
       * compare_type's `type >= MENU_SETTINGS_CORE_OPTION_START` branch
       * (core_setting_left/right) actually run - unlike MENU_ENUM_LABEL_
       * NO_ITEMS, which has its own case there and would silently eat
       * Left/Right input on these rows the same way it did for the Sound
       * submenu (see menu_displaylist_parse_pi_arcade_sound above). */
      if (core_option_manager_get_idx(coreopts, "mame_arcade_audio_boost_db", &idx))
         if (menu_entries_append(list,
                  "Audio Boost", "",
                  MENU_ENUM_LABEL_CORE_OPTION_ENTRY,
                  (unsigned)(MENU_SETTINGS_CORE_OPTION_START + idx),
                  0, 0, NULL))
            count++;

      if (core_option_manager_get_idx(coreopts, "mame_arcade_audio_stereo", &idx))
         if (menu_entries_append(list,
                  "Stereo/Mono", "",
                  MENU_ENUM_LABEL_CORE_OPTION_ENTRY,
                  (unsigned)(MENU_SETTINGS_CORE_OPTION_START + idx),
                  0, 0, NULL))
            count++;
   }

   if (count == 0)
      if (menu_entries_append(list,
               "No Game Audio options (not running an arcade/MAME title)", "",
               MENU_ENUM_LABEL_NO_ITEMS, MENU_SETTINGS_CORE_OPTION_NONE,
               0, 0, NULL))
         count++;

   return count;
}

'''

patch_file("menu/menu_displaylist.c", [
    ("standard C library includes for the wpctl helpers",
     "#include <compat/strcasestr.h>\n",
     "#include <compat/strcasestr.h>\n\n"
     "#include <stdio.h>\n"
     "#include <stdlib.h>\n"
     "#include <string.h>\n"
     "#include <ctype.h>\n"),
    ("include pi_arcade_sound.h",
     '#include "menu_driver.h"\n',
     '#include "menu_driver.h"\n#include "pi_arcade_sound.h"\n'),
    ("wpctl helper implementation + content-builders",
     "static int menu_displaylist_parse_load_content_settings(\n"
     "      file_list_t *list, settings_t *settings,\n"
     "      bool horizontal)\n",
     helper_impl +
     "static int menu_displaylist_parse_load_content_settings(\n"
     "      file_list_t *list, settings_t *settings,\n"
     "      bool horizontal)\n"),
    ("wire Sound/Game Audio pushes + Display Brightness into Quick Menu",
     "      if (!settings->bools.kiosk_mode_enable)\n"
     "      {\n"
     "         if (settings->bools.quick_menu_show_options)\n"
     "         {\n"
     "            /* Empty 'path' string signifies top level\n"
     "             * core options menu */\n"
     "            if (menu_entries_append(list,\n"
     "                     \"\",\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_CORE_OPTIONS),\n"
     "                     MENU_ENUM_LABEL_CORE_OPTIONS,\n"
     "                     MENU_SETTING_ACTION_CORE_OPTIONS, 0, 0, NULL))\n"
     "               count++;\n"
     "         }\n",
     "      if (!settings->bools.kiosk_mode_enable)\n"
     "      {\n"
     "         if (settings->bools.quick_menu_show_options)\n"
     "         {\n"
     "            /* Empty 'path' string signifies top level\n"
     "             * core options menu */\n"
     "            if (menu_entries_append(list,\n"
     "                     \"\",\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_CORE_OPTIONS),\n"
     "                     MENU_ENUM_LABEL_CORE_OPTIONS,\n"
     "                     MENU_SETTING_ACTION_CORE_OPTIONS, 0, 0, NULL))\n"
     "               count++;\n"
     "\n"
     "            /* pi-arcade-setup: Game Audio (MAME arcade audio boost /\n"
     "             * stereo-mono, mirroring the two core options MAME's\n"
     "             * own libretro fork registers) */\n"
     "            if (menu_entries_append(list,\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_VALUE_QUICK_MENU_GAME_AUDIO),\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO),\n"
     "                     MENU_ENUM_LABEL_QUICK_MENU_GAME_AUDIO,\n"
     "                     MENU_SETTING_ACTION, 0, 0, NULL))\n"
     "               count++;\n"
     "\n"
     "            /* pi-arcade-setup: Sound (system output device/volume/\n"
     "             * mute via wpctl) */\n"
     "            if (menu_entries_append(list,\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_VALUE_QUICK_MENU_SOUND),\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_QUICK_MENU_SOUND),\n"
     "                     MENU_ENUM_LABEL_QUICK_MENU_SOUND,\n"
     "                     MENU_SETTING_ACTION, 0, 0, NULL))\n"
     "               count++;\n"
     "\n"
     "            /* pi-arcade-setup: Display Brightness - reuses\n"
     "             * RetroArch's own already-working brightness setting\n"
     "             * (MENU_ENUM_LABEL_BRIGHTNESS_CONTROL), the same macro\n"
     "             * RetroArch itself uses to inject \"State Slot\" into\n"
     "             * this same screen a few lines below */\n"
     "            if (frontend_driver_can_set_screen_brightness())\n"
     "               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(list,\n"
     "                        MENU_ENUM_LABEL_BRIGHTNESS_CONTROL, PARSE_ONLY_UINT, true) == 0)\n"
     "                  count++;\n"
     "         }\n"),
    ("wire into menu_displaylist_build_list() switch",
     "      case DISPLAYLIST_CONTENT_SETTINGS:\n"
     "         count = menu_displaylist_parse_load_content_settings(list,\n"
     "               settings, false);\n"
     "\n"
     "         if (count == 0)\n"
     "            if (menu_entries_append(list,\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_VALUE_NO_ITEMS),\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_NO_ITEMS),\n"
     "                     MENU_ENUM_LABEL_NO_ITEMS,\n"
     "                     MENU_SETTING_NO_ITEM, 0, 0, NULL))\n"
     "               count++;\n"
     "         break;\n"
     "      case DISPLAYLIST_BROWSE_URL_START:\n",
     "      case DISPLAYLIST_CONTENT_SETTINGS:\n"
     "         count = menu_displaylist_parse_load_content_settings(list,\n"
     "               settings, false);\n"
     "\n"
     "         if (count == 0)\n"
     "            if (menu_entries_append(list,\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_VALUE_NO_ITEMS),\n"
     "                     msg_hash_to_str(MENU_ENUM_LABEL_NO_ITEMS),\n"
     "                     MENU_ENUM_LABEL_NO_ITEMS,\n"
     "                     MENU_SETTING_NO_ITEM, 0, 0, NULL))\n"
     "               count++;\n"
     "         break;\n"
     "      case DISPLAYLIST_PI_ARCADE_SOUND:\n"
     "         count = menu_displaylist_parse_pi_arcade_sound(list);\n"
     "         break;\n"
     "      case DISPLAYLIST_PI_ARCADE_GAME_AUDIO:\n"
     "         count = menu_displaylist_parse_pi_arcade_game_audio(list);\n"
     "         break;\n"
     "      case DISPLAYLIST_BROWSE_URL_START:\n"),
    ("wire into menu_displaylist_ctl() shared case group",
     "         case DISPLAYLIST_SUBSYSTEM_SETTINGS_LIST:\n"
     "#ifdef HAVE_MIST\n"
     "         case DISPLAYLIST_STEAM_SETTINGS_LIST:\n"
     "#endif\n"
     "         case DISPLAYLIST_OPTIONS_OVERRIDES:\n",
     "         case DISPLAYLIST_SUBSYSTEM_SETTINGS_LIST:\n"
     "#ifdef HAVE_MIST\n"
     "         case DISPLAYLIST_STEAM_SETTINGS_LIST:\n"
     "#endif\n"
     "         case DISPLAYLIST_PI_ARCADE_SOUND:\n"
     "         case DISPLAYLIST_PI_ARCADE_GAME_AUDIO:\n"
     "         case DISPLAYLIST_OPTIONS_OVERRIDES:\n"),
    ("wire Sound into the standalone/content-less Main Menu (reuses the\n"
     "     existing MENU_ENUM_LABEL_QUICK_MENU_SOUND OK-dispatch entry, so\n"
     "     no separate action_ok wiring is needed here)",
     "               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(info->list,\n"
     "                        MENU_ENUM_LABEL_SETTINGS, PARSE_ACTION, false) == 0)\n"
     "                  count++;\n"
     "               if (settings->bools.menu_show_information)\n",
     "               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(info->list,\n"
     "                        MENU_ENUM_LABEL_SETTINGS, PARSE_ACTION, false) == 0)\n"
     "                  count++;\n"
     "               /* pi-arcade-setup: Sound (system output device/volume/\n"
     "                * mute via wpctl) - also reachable standalone, not just\n"
     "                * from a running game's Quick Menu */\n"
     "               if (menu_entries_append(info->list,\n"
     "                        msg_hash_to_str(MENU_ENUM_LABEL_VALUE_QUICK_MENU_SOUND),\n"
     "                        msg_hash_to_str(MENU_ENUM_LABEL_QUICK_MENU_SOUND),\n"
     "                        MENU_ENUM_LABEL_QUICK_MENU_SOUND,\n"
     "                        MENU_SETTING_ACTION, 0, 0, NULL))\n"
     "                  count++;\n"
     "               if (settings->bools.menu_show_information)\n"),
])

sys.exit(overall_rc[0])
PYEOF
    return $?
}

# Fixes RetroArch's unix frontend driver's hardcoded
# "/sys/class/backlight/backlight/..." brightness path (only correct when
# a device tree explicitly sets `label = "backlight";`, which this
# hardware's touchscreen panel does not) to auto-detect whatever backlight
# device sysfs actually exposes instead - the same glob-first-match
# approach this project's own (now removed) controller-hotkeys.py used for
# the exact same problem. Falls back to the old hardcoded path if no
# backlight device is found at all, preserving old behavior in that case.
_apply_retroarch_brightness_wraparound_patch() {
    local ra_src_dir="$1"
    python3 - "$ra_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
path = root / "menu/menu_setting.c"
if not path.exists():
    print("[patch] menu/menu_setting.c: file not found, skipping (RetroArch source may have changed)")
    sys.exit(3)

text = path.read_text()
rc = 0

# BUG FOUND LIVE (disclosed per the user's request to note and fix any
# errors along the way): holding the stick left on the new "Display
# Brightness" Quick Menu entry drove the value down to the minimum (5%)
# and then, on the very next step, it jumped straight back up to the
# maximum (100%) instead of clamping - a visible "loop". Root cause: the
# generic uint left/right handlers RetroArch itself already uses for
# every classic-settings uint value (setting_uint_action_left_default /
# _right_default, in this same file) check *both*
# SD_FLAG_ENFORCE_MINRANGE/MAXRANGE (clamp at the edge) *and*
# settings->bools.menu_navigation_wraparound_enable - and if the latter
# is true (it is, on this cabinet's retroarch.cfg, so that scrolling
# through menu *lists* wraps top-to-bottom, which is desirable there),
# hitting the edge of a *value* slider wraps to the opposite end instead
# of clamping. That's fine for list navigation but wrong for a
# continuous value like brightness. Since this project doesn't want to
# turn off list-wraparound globally (that's a separate, desirable UX
# behavior elsewhere in the menu), the fix adds two small clamp-only
# left/right handlers used *only* for this one setting, instead of
# reaching for the shared default handler.
anchor_old = '''static int setting_bool_action_right_with_refresh(
      rarch_setting_t *setting, size_t idx, bool wraparound)
{'''
anchor_new = '''/* pi-arcade-setup: clamp-only uint left/right handlers, used only for
 * "Display Brightness" (see phase_retroarch_menu_rotation_patch's
 * quickmenu-extensions patch) so it doesn't wrap around at 5%/100% even
 * though menu_navigation_wraparound_enable is true (which is wanted for
 * ordinary list scrolling, just not for a value slider). Mirrors
 * setting_uint_action_left_default/_right_default above minus the
 * wraparound branch. */
static int pi_arcade_brightness_action_left(
      rarch_setting_t *setting, size_t idx, bool wraparound)
{
   bool  overflowed = false;
   float step        = 0.0f;

   if (!setting)
      return -1;

   step = recalc_step_based_on_length_of_action(setting);

   if (step > *setting->value.target.unsigned_integer)
      overflowed = true;
   else
      *setting->value.target.unsigned_integer =
         *setting->value.target.unsigned_integer - step;

   if (setting->flags & SD_FLAG_ENFORCE_MINRANGE)
   {
      float min = setting->min;
      if (overflowed || *setting->value.target.unsigned_integer < min)
         *setting->value.target.unsigned_integer = min;
   }

   return 0;
}

static int pi_arcade_brightness_action_right(
      rarch_setting_t *setting, size_t idx, bool wraparound)
{
   float step = 0.0f;

   if (!setting)
      return -1;

   step = recalc_step_based_on_length_of_action(setting);

   *setting->value.target.unsigned_integer =
      *setting->value.target.unsigned_integer + step;

   if (setting->flags & SD_FLAG_ENFORCE_MAXRANGE)
   {
      float max = setting->max;
      if (*setting->value.target.unsigned_integer > max)
         *setting->value.target.unsigned_integer = max;
   }

   return 0;
}

static int setting_bool_action_right_with_refresh(
      rarch_setting_t *setting, size_t idx, bool wraparound)
{'''
# NOTE: anchor_new deliberately ENDS with the exact same text as
# anchor_old (my new functions are inserted immediately before the
# untouched setting_bool_action_right_with_refresh signature), so
# anchor_old stays a substring of the file forever after patching -
# checking "anchor_old in text" first (the usual pattern elsewhere in
# this script) would misfire and re-insert a duplicate definition on
# every re-run. Use a marker that only exists post-patch instead.
already_applied_marker = "static int pi_arcade_brightness_action_left("
if already_applied_marker in text:
    print("[patch] menu_setting.c clamp-only brightness handlers: already applied")
elif anchor_old in text:
    text = text.replace(anchor_old, anchor_new, 1)
    print("[patch] menu_setting.c clamp-only brightness handlers: applied")
else:
    print("[patch] menu_setting.c clamp-only brightness handlers: anchor text not found, skipping (RetroArch source may have changed)")
    rc = 3

wire_old = '''                (*list)[list_info->index - 1].ui_type = ST_UI_TYPE_UINT_COMBOBOX;
                (*list)[list_info->index - 1].action_ok = &setting_action_ok_uint_special;
                (*list)[list_info->index - 1].get_string_representation =
                   &setting_get_string_representation_percentage;
                menu_settings_list_current_add_range(list, list_info, 5, 100, 5, true, true);'''
wire_new = '''                (*list)[list_info->index - 1].ui_type = ST_UI_TYPE_UINT_COMBOBOX;
                (*list)[list_info->index - 1].action_ok = &setting_action_ok_uint_special;
                /* pi-arcade-setup: clamp instead of wrap at 5%/100% - see
                 * pi_arcade_brightness_action_left/_right above. */
                (*list)[list_info->index - 1].action_left = &pi_arcade_brightness_action_left;
                (*list)[list_info->index - 1].action_right = &pi_arcade_brightness_action_right;
                (*list)[list_info->index - 1].get_string_representation =
                   &setting_get_string_representation_percentage;
                menu_settings_list_current_add_range(list, list_info, 5, 100, 5, true, true);'''
if wire_old in text:
    text = text.replace(wire_old, wire_new, 1)
    print("[patch] menu_setting.c brightness left/right wiring: applied")
elif wire_new in text:
    print("[patch] menu_setting.c brightness left/right wiring: already applied")
else:
    print("[patch] menu_setting.c brightness left/right wiring: anchor text not found, skipping (RetroArch source may have changed) - Display Brightness will keep wrapping around at min/max")
    rc = 3

path.write_text(text)
sys.exit(rc)
PYEOF
    return $?
}

_apply_retroarch_backlight_path_patch() {
    local ra_src_dir="$1"
    python3 - "$ra_src_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
path = root / "frontend/drivers/platform_unix.c"
if not path.exists():
    print("[patch] frontend/drivers/platform_unix.c: file not found, skipping (RetroArch source may have changed)")
    sys.exit(3)

text = path.read_text()
rc = 0

old_inc = "#include <fcntl.h>\n"
new_inc = "#include <fcntl.h>\n#include <glob.h>\n"
if new_inc in text:
    print("[patch] platform_unix.c include: already applied")
elif old_inc not in text:
    print("[patch] platform_unix.c include: anchor text not found, skipping (RetroArch source may have changed)")
    rc = 3
else:
    text = text.replace(old_inc, new_inc, 1)
    print("[patch] platform_unix.c include: applied")

old_fn = '''static void frontend_unix_set_screen_brightness(int value)
{
   char *buffer = NULL;
   char svalue[16] = {0};
   unsigned int max_brightness = 100;

   /* Device tree should have 'label = "backlight";' if control is desirable */
   filestream_read_file("/sys/class/backlight/backlight/max_brightness",
                        (void **)&buffer, NULL);
   if (buffer)
   {
      sscanf(buffer, "%u", &max_brightness);
      free(buffer);
   }

   /* Calculate the brightness */
   value = (value * max_brightness) / 100;

   snprintf(svalue, sizeof(svalue), "%d\\n", value);
   filestream_write_file("/sys/class/backlight/backlight/brightness",
                         svalue, strlen(svalue));
}'''
new_fn = '''static void frontend_unix_set_screen_brightness(int value)
{
   char *buffer = NULL;
   char svalue[16] = {0};
   unsigned int max_brightness = 100;
   static char backlight_path[512] = {0};
   static bool backlight_path_resolved = false;
   char max_path[560];
   char brightness_path[560];

   /* pi-arcade-setup: auto-detect the actual backlight device name (e.g.
    * "10-0045" on the official 7" touchscreen, or a vendor-specific name
    * on other panels) instead of assuming a fixed "backlight" device node
    * exists - that fixed name is only present when the device tree sets
    * 'label = "backlight";', which most panels (including this project's
    * target hardware) do not. Falls back to the old fixed name if no
    * backlight device is found at all, preserving old behavior. Resolved
    * once and cached (the backlight device doesn't change at runtime). */
   if (!backlight_path_resolved)
   {
      glob_t gl;
      backlight_path_resolved = true;
      strlcpy(backlight_path, "/sys/class/backlight/backlight", sizeof(backlight_path));
      if (glob("/sys/class/backlight/*", 0, NULL, &gl) == 0 && gl.gl_pathc > 0)
      {
         strlcpy(backlight_path, gl.gl_pathv[0], sizeof(backlight_path));
         globfree(&gl);
      }
   }

   snprintf(max_path, sizeof(max_path), "%s/max_brightness", backlight_path);
   snprintf(brightness_path, sizeof(brightness_path), "%s/brightness", backlight_path);

   /* Device tree should have 'label = "backlight";' if control is desirable */
   filestream_read_file(max_path,
                        (void **)&buffer, NULL);
   if (buffer)
   {
      sscanf(buffer, "%u", &max_brightness);
      free(buffer);
   }

   /* Calculate the brightness */
   value = (value * max_brightness) / 100;

   snprintf(svalue, sizeof(svalue), "%d\\n", value);
   filestream_write_file(brightness_path,
                         svalue, strlen(svalue));
}'''
if new_fn in text:
    print("[patch] platform_unix.c frontend_unix_set_screen_brightness: already applied")
elif old_fn not in text:
    print("[patch] platform_unix.c frontend_unix_set_screen_brightness: anchor text not found, skipping (RetroArch source may have changed)")
    rc = 3
else:
    text = text.replace(old_fn, new_fn, 1)
    print("[patch] platform_unix.c frontend_unix_set_screen_brightness: applied")

# ERROR FOUND LIVE (disclosed per the user's request to note and fix any
# errors along the way): frontend_ctx_unix's set_screen_brightness struct
# field is ONLY wired to frontend_unix_set_screen_brightness when built
# for Lakka (HAVE_LAKKA_SWITCH, or HAVE_LAKKA+HAVE_ODROIDGO2) - on a plain
# RetroPie/Debian unix build (this project's target, no HAVE_LAKKA), it's
# unconditionally NULL, so frontend_driver_can_set_screen_brightness()
# always returns false and BOTH the stock Settings > ... > Brightness
# Control entry AND this patch's new Quick Menu "Display Brightness" entry
# silently fail to appear at all - confirmed live: the entry was verified
# completely absent from the real in-game Quick Menu after the first
# build of this patch, traced to this exact Lakka-only compile guard.
# Fixed by wiring the function unconditionally - safe on non-Lakka/non-
# backlight hardware too, since the auto-detect glob() above simply finds
# no device and the write silently no-ops in that case, matching every
# other "not applicable on this hardware" fallback elsewhere in this
# project.
old_gate = '''#if defined(HAVE_LAKKA_SWITCH) || (defined(HAVE_LAKKA) && defined(HAVE_ODROIDGO2))
   frontend_unix_set_screen_brightness,/* set_screen_brightness */
#else
   NULL,                         /* set_screen_brightness */
#endif'''
new_gate = '''   frontend_unix_set_screen_brightness,/* set_screen_brightness */'''
# NOTE: new_gate is deliberately checked AFTER old_gate below, not before -
# new_gate's exact text is also a substring of old_gate itself (the still-
# guarded #if branch contains this same line), so checking new_gate first
# would wrongly report "already applied" on a completely unpatched file.
if old_gate in text:
    text = text.replace(old_gate, new_gate, 1)
    print("[patch] platform_unix.c set_screen_brightness struct wiring: applied")
elif new_gate in text:
    print("[patch] platform_unix.c set_screen_brightness struct wiring: already applied")
else:
    print("[patch] platform_unix.c set_screen_brightness struct wiring: anchor text not found, skipping (RetroArch source may have changed) - Display Brightness Quick Menu entry will not appear")
    rc = 3

# SECOND ERROR FOUND LIVE, after the struct-wiring fix above: the struct
# now unconditionally references frontend_unix_set_screen_brightness, but
# the FUNCTION ITSELF is still compiled out on non-Lakka builds - it lives
# inside the SAME "#ifdef HAVE_LAKKA" block as frontend_unix_get_lakka_version
# (one #ifdef/#endif pair wraps both functions). Result: a real compile
# error ('frontend_unix_set_screen_brightness' undeclared here) on the
# first rebuild attempt after the struct-wiring fix, confirmed live on the
# Pi. Fixed by splitting that single guarded block into two: get_lakka_version
# stays Lakka-only (it shells out to "cat /etc/release", meaningless off
# Lakka), while set_screen_brightness becomes unconditional, matching the
# now-unconditional struct reference.
old_boundary = '''   pclose(command_file);
}

static void frontend_unix_set_screen_brightness(int value)'''
new_boundary = '''   pclose(command_file);
}
#endif

static void frontend_unix_set_screen_brightness(int value)'''
if old_boundary in text:
    text = text.replace(old_boundary, new_boundary, 1)
    print("[patch] platform_unix.c HAVE_LAKKA guard split (open): applied")
elif new_boundary in text:
    print("[patch] platform_unix.c HAVE_LAKKA guard split (open): already applied")
else:
    print("[patch] platform_unix.c HAVE_LAKKA guard split (open): anchor text not found, skipping (RetroArch source may have changed)")
    rc = 3

old_tail = '''
#endif

static void frontend_unix_get_env(int *argc,'''
new_tail = '''

static void frontend_unix_get_env(int *argc,'''
if old_tail in text:
    text = text.replace(old_tail, new_tail, 1)
    print("[patch] platform_unix.c HAVE_LAKKA guard split (close): applied")
elif new_tail in text:
    print("[patch] platform_unix.c HAVE_LAKKA guard split (close): already applied")
else:
    print("[patch] platform_unix.c HAVE_LAKKA guard split (close): anchor text not found, skipping (RetroArch source may have changed) - build will fail with 'frontend_unix_set_screen_brightness undeclared'")
    rc = 3

path.write_text(text)
sys.exit(rc)
PYEOF
    return $?
}

# RetroArch ships a large library of controller autoconfig profiles under
# .../retroarch/autoconfig-presets/udev/ (hundreds of pads, matched by
# vendor/product id), but only copies a profile into the *active*
# autoconfig directory when you walk a specific controller through classic
# EmulationStation's own input-configuration screen. ES-DE does not do this
# at all. The practical effect: a controller can work fine for menu
# navigation (SDL2, read directly) while doing nothing inside actual games
# (RetroArch's udev joypad driver has no profile to match it against). This
# copies the whole preset library into the active directory once, up front,
# so any common controller "just works" in-game without that manual step.
phase_retroarch_autoconfig() {
    local preset_dir="/opt/retropie/emulators/retroarch/autoconfig-presets/udev"
    local active_dir="/opt/retropie/configs/all/retroarch/autoconfig"
    if [ ! -d "$preset_dir" ]; then
        log_warn "RetroArch autoconfig preset library not found at $preset_dir; skipping"
        return 0
    fi
    sudo mkdir -p "$active_dir"
    # -n: never overwrite a profile that's already there (e.g. one already
    # generated for a controller that went through EmulationStation's own
    # input configuration, which may have hand-tuned hotkey bindings).
    sudo cp -n "$preset_dir"/*.cfg "$active_dir"/ 2>/dev/null
    sudo chown "$PI_USER":"$PI_USER" "$active_dir"/*.cfg 2>/dev/null
    log "Populated RetroArch autoconfig directory with $(ls "$active_dir"/*.cfg 2>/dev/null | wc -l) controller profiles"
    return 0
}

# Set the given key to the given value in a RetroArch cfg file - handles a
# commented-out default, an existing set value, or the key being entirely
# absent (appends it).
_set_retroarch_key() {
    local file="$1" key="$2" val="$3"
    [ -f "$file" ] || return 0
    if grep -q "^${key} *=" "$file"; then
        sudo sed -i "s|^${key} *=.*|${key} = ${val}|" "$file"
    elif grep -q "^# *${key} *=" "$file"; then
        sudo sed -i "s|^# *${key} *=.*|${key} = ${val}|" "$file"
    else
        echo "${key} = ${val}" | sudo tee -a "$file" >/dev/null
    fi
}

phase_video_rotation_setup() {
    local all_cfg="/opt/retropie/configs/all/retroarch.cfg"
    # NOTE: video_allow_rotate=false (letting only the fixed video_rotation
    # apply, ignoring what a libretro core like MAME reports for a vertical
    # cabinet game) was tried live on the reference Pi and reverted - it
    # fixed nothing for a vertical game (Pac-Man) and broke horizontal ones
    # (Mortal Kombat came out rotated). true is the correct/default setting -
    # MAME's own default mame_rotation_mode="libretro" (auto, per-ROM) already
    # handles vertical-cabinet games correctly with video_allow_rotate=true;
    # no per-ROM override is needed (see the comment near
    # phase_retroarch_menu_rotation_patch and the aspect/viewport code below
    # for what the actual rotation bugs turned out to be - not the CPU/GPU
    # overclock, despite an earlier pass through this project blaming it).
    _set_retroarch_key "$all_cfg" "video_allow_rotate" "true"
    _set_retroarch_key "$all_cfg" "video_rotation" "$RETROARCH_VIDEO_ROTATION"
    # RetroPad combo to quit straight back to the frontend (4 = Start +
    # Select) - unset by default upstream, which is why Start+Select alone
    # did nothing before this (confirmed live on the reference Pi).
    _set_retroarch_key "$all_cfg" "input_quit_gamepad_combo" "4"

    # See the PANEL_NATIVE_WIDTH/HEIGHT comment above for *why* a manual
    # custom viewport is needed at all - it exists purely to compensate for
    # a RetroArch aspect-fit bug that only bites when a rotated panel/
    # monitor is involved (the viewport gets fit against the panel's
    # *native*, pre-rotation dimensions, not the actual displayed
    # orientation). With RETROARCH_VIDEO_ROTATION=0 (a plain, unrotated
    # HDMI monitor - the setup wizard's own default for HDMI-without-
    # rotation) there is no coordinate-space mismatch to correct: native and
    # displayed dimensions are the same thing, so RetroArch's own normal
    # auto-aspect handling already does the right thing unassisted.
    # Confirmed by re-reading the same aspect-fit code path this override
    # was originally written against - the bug is specifically in how a
    # non-zero video_rotation is combined with the aspect calculation, not
    # present at all when video_rotation is 0. Skipping this whole override
    # in that case also means PANEL_NATIVE_WIDTH/HEIGHT don't need to be
    # known at all for the common plain-HDMI case, which the wizard doesn't
    # even ask about when rotation is off.
    if [ "$RETROARCH_VIDEO_ROTATION" = "0" ]; then
        log "RETROARCH_VIDEO_ROTATION=0 - leaving aspect_ratio_index/custom_viewport/video_aspect_ratio_auto/video_scale_integer at RetroArch's own defaults (no rotation-compensation viewport needed)"
    else
        # Computed here (not hardcoded) so it scales with PANEL_NATIVE_WIDTH/
        # HEIGHT for a different panel/monitor: fills the native width fully
        # (becomes the final height post-rotation), height is a standard 4:3
        # box (becomes the final width post-rotation), vertically centered in
        # native coordinates (becomes horizontally centered post-rotation).
        # All values are in *native* (pre-rotation) coordinates - see the
        # comment above, this is not the same coordinate space as the final
        # displayed image.
        local viewport_w=$PANEL_NATIVE_WIDTH
        local viewport_h=$(( PANEL_NATIVE_WIDTH * 4 / 3 ))
        local viewport_x=0
        local viewport_y=$(( (PANEL_NATIVE_HEIGHT - viewport_h) / 2 ))
        _set_retroarch_key "$all_cfg" "video_aspect_ratio_auto" "false"
        _set_retroarch_key "$all_cfg" "video_scale_integer" "false"
        _set_retroarch_key "$all_cfg" "video_scale_integer_overscale" "false"
        _set_retroarch_key "$all_cfg" "aspect_ratio_index" "23"
        _set_retroarch_key "$all_cfg" "custom_viewport_width" "$viewport_w"
        _set_retroarch_key "$all_cfg" "custom_viewport_height" "$viewport_h"
        _set_retroarch_key "$all_cfg" "custom_viewport_x" "$viewport_x"
        _set_retroarch_key "$all_cfg" "custom_viewport_y" "$viewport_y"
        log "Set aspect_ratio_index=23 (Custom), custom_viewport=${viewport_w}x${viewport_h}+${viewport_x}+${viewport_y} (native/pre-rotation coordinates), video_aspect_ratio_auto=false, video_scale_integer=false"
    fi

    # configs/arcade/retroarch.cfg #includes the global file above, and per
    # its own header comment, keys placed *after* that #include line are
    # ignored (RetroArch's config parser keeps the first assignment it
    # sees) - so an override has to be inserted *above* the #include, not
    # just appended to the end of the file.
    local arcade_cfg="/opt/retropie/configs/arcade/retroarch.cfg"
    if [ -f "$arcade_cfg" ]; then
        if grep -q "^video_allow_rotate" "$arcade_cfg"; then
            sudo sed -i "s|^video_allow_rotate.*|video_allow_rotate = true|" "$arcade_cfg"
        else
            sudo sed -i "/^#include/i video_allow_rotate = true" "$arcade_cfg"
        fi
        if grep -q "^video_rotation" "$arcade_cfg"; then
            sudo sed -i "s|^video_rotation.*|video_rotation = $RETROARCH_VIDEO_ROTATION|" "$arcade_cfg"
        else
            sudo sed -i "/^#include/i video_rotation = $RETROARCH_VIDEO_ROTATION" "$arcade_cfg"
        fi
        # Makes the left analog stick also work as a digital d-pad for the
        # arcade system specifically - needed for MAME's own in-game UI
        # (its stock Show/Hide Menu: save states, DIP switches, etc.) to
        # respond to stick input at all. Confirmed live: RetroArch's
        # per-controller autoconfig binds a real D-pad/HAT to digital
        # left/right (e.g. input_left_btn="h0left") but leaves the analog
        # stick axes bound only to the *analog* RETRO_DEVICE_ANALOG inputs,
        # not the digital retropad directions - and
        # input_player*_analog_dpad_mode defaults to "0" (None), so without
        # this, moving the stick produces no digital signal at all. MAME's
        # own ioport-driven UI (IPT_UI_LEFT/RIGHT/UP/DOWN) only ever sees
        # digital retropad directions, so it's otherwise unreachable by the
        # stick, even though RetroArch's own separate Quick Menu (including
        # its Display Brightness/Sound/Game Audio entries added by
        # _apply_retroarch_quickmenu_extensions_patch) navigates fine by
        # stick already (it reads raw analog axes directly, an entirely
        # different, core-independent code path).
        #
        # Must be the *_FORCED variant ("3" = ANALOG_DPAD_LSTICK_FORCED),
        # not plain "Left Analog" ("1") - confirmed by reading RetroArch's
        # own input_driver.c: a non-forced analog_dpad_mode is silently
        # downgraded back to None for any port where the core has ever
        # polled RETRO_DEVICE_ANALOG (input_driver_analog_requested), and
        # retro-mame's own input_retro.cpp unconditionally polls both
        # analog sticks for every game regardless of whether that specific
        # ROM's hardware uses them - so plain "1" silently does nothing for
        # this core specifically, confirmed live: it looked set in the cfg
        # file but had no effect at all in-game. The forced variant skips
        # that downgrade check entirely. Trade-off, also confirmed via the
        # same source: forcing this replaces the stick's raw analog output
        # with digital-only left/right/up/down for as long as it's active,
        # so a genuinely analog-control arcade game (rare, but they exist)
        # would no longer get real analog values from the left stick - an
        # acceptable trade here since MAME ROMs are overwhelmingly
        # digital-input hardware to begin with, and the D-pad/HAT is
        # unaffected regardless. Scoped to this arcade-only config (not the
        # global all/retroarch.cfg), so PSX/N64/etc. analog gameplay
        # elsewhere is untouched. Set for players 1 and 2 to cover common
        # two-player cabinets; higher player numbers are left alone.
        for _p in 1 2; do
            if grep -q "^input_player${_p}_analog_dpad_mode" "$arcade_cfg"; then
                sudo sed -i "s|^input_player${_p}_analog_dpad_mode.*|input_player${_p}_analog_dpad_mode = \"3\"|" "$arcade_cfg"
            else
                sudo sed -i "/^#include/i input_player${_p}_analog_dpad_mode = \"3\"" "$arcade_cfg"
            fi
        done
        log "Set video_allow_rotate=true, video_rotation=$RETROARCH_VIDEO_ROTATION, input_player1/2_analog_dpad_mode=3 (Left Analog, Forced) in arcade/retroarch.cfg; input_quit_gamepad_combo=4 (Start+Select) in all/retroarch.cfg"
    else
        log_warn "arcade/retroarch.cfg not found yet - set video_allow_rotate/video_rotation in all/retroarch.cfg only; the arcade system will still inherit it via #include, but the analog-stick-as-dpad fix (arcade-only) will be skipped"
    fi

    # RGUI's own aspect-lock setting is separate from the content viewport
    # fix above, and defaults to INTEGER (whole-pixel-multiple scaling only),
    # which left the standalone Main Menu looking too narrow once its
    # rotation was also fixed (see _apply_retroarch_menu_rotation_patch) -
    # NONE lets it fill the screen like everything else here.
    _set_retroarch_key "$all_cfg" "rgui_aspect_ratio_lock" "0"

    # Xbox-style pads (and others following the same physical-position
    # convention) map their bottom face button to retro-B and right face
    # button to retro-A - RetroArch's menu then reads as "B confirms, A
    # backs out", which is backwards from what most people expect. This
    # swaps it to the more intuitive "A confirms, B backs out" without
    # touching any actual button mapping (confirmed via source - a real,
    # driver-agnostic input setting, not an ozone/xmb cosmetic option, and
    # needs no recompile).
    _set_retroarch_key "$all_cfg" "menu_swap_ok_cancel_buttons" "true"
    log "Set rgui_aspect_ratio_lock=0 (None), menu_swap_ok_cancel_buttons=true in all/retroarch.cfg"
    return 0
}

phase_ftp_install() {
    sudo apt-get install -y proftpd-core proftpd-doc || log_warn "proftpd install failed"
    return 0
}

phase_disk_cleanup() {
    sudo apt-get autoremove -y || true
    sudo apt-get clean || true
    df -h / | sudo tee -a "$LOG_FILE" >/dev/null
    return 0
}

phase_esde_build_deps() {
    sudo apt-get update -y
    sudo apt-get install -y \
        clang-format cmake gettext libharfbuzz-dev libicu-dev libsdl2-dev \
        libavcodec-dev libavfilter-dev libavformat-dev libavutil-dev \
        libfreeimage-dev libfreetype6-dev libgit2-dev libcurl4-gnutls-dev \
        libpugixml-dev libbluetooth-dev libpoppler-cpp-dev \
        libgles2-mesa-dev libegl1-mesa-dev \
        pipewire pipewire-pulse wireplumber \
        build-essential python3 || die "ES-DE build dependency install failed"
    return 0
}

# Exact string replacement patch, matched against the real ES-DE stable-3.4
# source. Fails soft: if the anchor text isn't found (e.g. a newer/older
# ES-DE version with different surrounding code), it warns and leaves the
# file untouched rather than aborting the whole build.
_apply_quitmenu_patch() {
    local esde_dir="$1"
    python3 - "$esde_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])

def patch(path, old, new, label):
    p = root / path
    text = p.read_text()
    if new in text:
        print(f"[patch] {label}: already applied")
        return True
    if old not in text:
        print(f"[patch] {label}: anchor text not found, skipping (ES-DE source may have changed)")
        return False
    p.write_text(text.replace(old, new, 1))
    print(f"[patch] {label}: applied")
    return True

ok = True

ok &= patch(
    "es-core/src/utils/PlatformUtil.h",
    "        enum QuitMode {\n"
    "            QUIT = 0,\n"
    "            REBOOT = 1,\n"
    "            POWEROFF = 2\n"
    "        };",
    "        enum QuitMode {\n"
    "            QUIT = 0,\n"
    "            REBOOT = 1,\n"
    "            POWEROFF = 2,\n"
    "            RESTART = 3\n"
    "        };",
    "PlatformUtil.h enum QuitMode",
)

ok &= patch(
    "es-core/src/utils/PlatformUtil.cpp",
    '                case QuitMode::POWEROFF: {\n'
    '                    LOG(LogInfo) << "Powering off system";\n'
    '                    Scripting::fireEvent("poweroff");\n'
    '                    Scripting::fireEvent("quit");\n'
    '                    runPoweroffCommand();\n'
    '                    break;\n'
    '                }\n'
    '                default: {',
    '                case QuitMode::POWEROFF: {\n'
    '                    LOG(LogInfo) << "Powering off system";\n'
    '                    Scripting::fireEvent("poweroff");\n'
    '                    Scripting::fireEvent("quit");\n'
    '                    runPoweroffCommand();\n'
    '                    break;\n'
    '                }\n'
    '                case QuitMode::RESTART: {\n'
    '                    LOG(LogInfo) << "Restarting ES-DE";\n'
    '                    Scripting::fireEvent("restart");\n'
    '                    Scripting::fireEvent("quit");\n'
    '                    break;\n'
    '                }\n'
    '                default: {',
    "PlatformUtil.cpp processQuitMode()",
)

old_menu = (
    '#if !defined(__HAIKU__)\n'
    '        row.elements.clear();\n'
    '        row.makeAcceptInputHandler([window, this] {\n'
    '            window->pushGui(new GuiMsgBox(\n'
    '                _("REALLY SUSPEND?"), _("YES"),\n'
    '                [this] {\n'
    '                    LOG(LogInfo) << "Suspending system";\n'
    '                    Scripting::fireEvent("suspend");\n'
    '                    if (Utils::Platform::runSuspendCommand() != 0) {\n'
    '                        LOG(LogWarning) << "Couldn\'t suspend system";\n'
    '                    }\n'
    '                    else {\n'
    '                        this->close(true);\n'
    '                    }\n'
    '                },\n'
    '                _("NO"), nullptr));\n'
    '        });\n'
    '        auto suspendText = std::make_shared<TextComponent>(\n'
    '            _("SUSPEND SYSTEM"), Font::get(FONT_SIZE_MEDIUM), mMenuColorPrimary);\n'
    '        suspendText->setSelectable(true);\n'
    '        row.addElement(suspendText, true);\n'
    '        s->addRow(row);\n'
    '#endif'
)
new_menu = (
    '        row.elements.clear();\n'
    '        row.makeAcceptInputHandler([window, this] {\n'
    '            window->pushGui(new GuiMsgBox(\n'
    '                _("REALLY RESTART EMULATIONSTATION?"), _("YES"),\n'
    '                [this] {\n'
    '                    close(true);\n'
    '                    Utils::Platform::quitES(Utils::Platform::QuitMode::RESTART);\n'
    '                },\n'
    '                _("NO"), nullptr));\n'
    '        });\n'
    '        auto restartText = std::make_shared<TextComponent>(\n'
    '            _("RESTART EMULATIONSTATION"), Font::get(FONT_SIZE_MEDIUM), mMenuColorPrimary);\n'
    '        restartText->setSelectable(true);\n'
    '        row.addElement(restartText, true);\n'
    '        s->addRow(row);'
)
ok &= patch("es-app/src/guis/GuiMenu.cpp", old_menu, new_menu, "GuiMenu.cpp Quit menu (remove Suspend, add Restart EmulationStation)")

sys.exit(0 if ok else 3)
PYEOF
}

# Fixes a genuine upstream ES-DE crash when opening Main Menu > Scraper -
# see the APPLY_ESDE_SCRAPER_MENU_PATCH comment above for the full story.
# Same fail-soft exact-match pattern as _apply_quitmenu_patch.
_apply_scraper_menu_crash_patch() {
    local esde_dir="$1"
    python3 - "$esde_dir" <<'PYEOF'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
path = root / "es-app/src/guis/GuiScraperMenu.cpp"
text = path.read_text()

old = """    mSystems = std::make_shared<OptionListComponent<SystemData*>>(_("SCRAPE THESE SYSTEMS"), true);
    for (unsigned int i {0}; i < SystemData::sSystemVector.size(); ++i) {
        if (!SystemData::sSystemVector[i]->hasPlatformId(PlatformIds::PLATFORM_IGNORE)) {
            mSystems->add(Utils::String::toUpper(SystemData::sSystemVector[i]->getFullName()),
                          SystemData::sSystemVector[i],
                          !SystemData::sSystemVector[i]->getPlatformIds().empty());
            SystemData::sSystemVector[i]->getScrapeFlag() ? mSystems->selectEntry(i) :
                                                            mSystems->unselectEntry(i);
        }
    }"""

new = """    mSystems = std::make_shared<OptionListComponent<SystemData*>>(_("SCRAPE THESE SYSTEMS"), true);
    unsigned int mSystemsIndex {0};
    for (unsigned int i {0}; i < SystemData::sSystemVector.size(); ++i) {
        if (!SystemData::sSystemVector[i]->hasPlatformId(PlatformIds::PLATFORM_IGNORE)) {
            mSystems->add(Utils::String::toUpper(SystemData::sSystemVector[i]->getFullName()),
                          SystemData::sSystemVector[i],
                          !SystemData::sSystemVector[i]->getPlatformIds().empty());
            SystemData::sSystemVector[i]->getScrapeFlag() ? mSystems->selectEntry(mSystemsIndex) :
                                                            mSystems->unselectEntry(mSystemsIndex);
            ++mSystemsIndex;
        }
    }"""

if new in text:
    print("[patch] GuiScraperMenu.cpp scraper crash fix: already applied")
    sys.exit(0)
if old not in text:
    print("[patch] GuiScraperMenu.cpp scraper crash fix: anchor text not found, skipping (ES-DE source may have changed)")
    sys.exit(3)
path.write_text(text.replace(old, new, 1))
print("[patch] GuiScraperMenu.cpp scraper crash fix: applied")
sys.exit(0)
PYEOF
}

phase_esde_build() {
    if [ ! -d "$PI_HOME/emulationstation-de" ]; then
        git clone https://gitlab.com/es-de/emulationstation-de.git "$PI_HOME/emulationstation-de" || die "ES-DE clone failed"
    fi
    cd "$PI_HOME/emulationstation-de" || die "cannot cd into emulationstation-de"
    git fetch --depth=1 origin "$ESDE_BRANCH" || true
    git checkout "$ESDE_BRANCH" || die "checkout $ESDE_BRANCH failed"

    if [ "$APPLY_ESDE_QUITMENU_PATCH" = "true" ]; then
        _apply_quitmenu_patch "$PI_HOME/emulationstation-de" || log_warn "Quit-menu patch did not fully apply; ES-DE will build without the Restart EmulationStation option."
    fi

    if [ "$APPLY_ESDE_SCRAPER_MENU_PATCH" = "true" ]; then
        _apply_scraper_menu_crash_patch "$PI_HOME/emulationstation-de" || log_warn "Scraper menu crash patch did not fully apply; opening Main Menu > Scraper may crash ES-DE if any system is tagged platform=ignore (e.g. the custom RetroPie Setup system)."
    fi

    mkdir -p build && cd build || die "cannot cd into emulationstation-de/build"
    cmake -DGLES=on -DDEINIT_ON_LAUNCH=on -DAPPLICATION_UPDATER=off \
          -DCMAKE_INSTALL_PREFIX=/opt/es-de .. || die "ES-DE cmake configure failed"
    make -j"$(nproc)" || die "ES-DE build failed"
    sudo make install || die "ES-DE install failed"
    sudo chown -R "$PI_USER":"$PI_USER" "$PI_HOME/emulationstation-de"
    return 0
}

phase_esde_config() {
    mkdir -p "$PI_HOME/ES-DE/settings"
    if [ ! -f "$PI_HOME/ES-DE/settings/es_settings.xml" ]; then
        log "Launching ES-DE once to generate default es_settings.xml"
        local esde_run_rot_args=()
        [ "$ENABLE_DSI_DISPLAY" = "true" ] && esde_run_rot_args=(--screenrotate "$ESDE_SCREENROTATE")
        XDG_RUNTIME_DIR="/run/user/$(id -u "$PI_USER")" /opt/es-de/bin/es-de "${esde_run_rot_args[@]}" >/dev/null 2>&1 &
        local espid=$!
        sleep 8
        sudo pkill -f es-de 2>/dev/null || kill "$espid" 2>/dev/null || true
        sleep 2
    fi

    if [ -f "$PI_HOME/ES-DE/settings/es_settings.xml" ]; then
        sed -i "s|<string name=\"ROMDirectory\" value=\"[^\"]*\" />|<string name=\"ROMDirectory\" value=\"$PI_HOME/RetroPie/roms\" />|" "$PI_HOME/ES-DE/settings/es_settings.xml"
        if [ "$INSTALL_THEMES" = "true" ]; then
            sed -i "s|<string name=\"Theme\" value=\"[^\"]*\" />|<string name=\"Theme\" value=\"$ESDE_THEME_NAME\" />|" "$PI_HOME/ES-DE/settings/es_settings.xml"
        fi
        sed -i "s|<string name=\"ThemeAspectRatio\" value=\"[^\"]*\" />|<string name=\"ThemeAspectRatio\" value=\"$ESDE_THEME_ASPECT\" />|" "$PI_HOME/ES-DE/settings/es_settings.xml"
        if grep -q 'name="ShowQuitMenu"' "$PI_HOME/ES-DE/settings/es_settings.xml"; then
            sed -i 's|<bool name="ShowQuitMenu" value="[^"]*" />|<bool name="ShowQuitMenu" value="true" />|' "$PI_HOME/ES-DE/settings/es_settings.xml"
        fi
    else
        log_warn "es_settings.xml was not generated (ES-DE may need a real display/DRM device to run) - default settings will apply on first real launch."
    fi
    return 0
}

phase_esde_retroarch_links() {
    sudo ln -sf /opt/retropie/emulators/retroarch/bin/retroarch /usr/local/bin/retroarch
    [ -x /opt/retropie/emulators/ppsspp/PPSSPPSDL ] && sudo ln -sf /opt/retropie/emulators/ppsspp/PPSSPPSDL /usr/local/bin/PPSSPPSDL

    mkdir -p "$PI_HOME/.config/retroarch"
    [ -f /opt/retropie/configs/all/retroarch.cfg ] && ln -sf /opt/retropie/configs/all/retroarch.cfg "$PI_HOME/.config/retroarch/retroarch.cfg"

    mkdir -p "$PI_HOME/.config/retroarch/cores"

    # Symlink EVERY libretro core actually installed under
    # /opt/retropie/libretrocores/*/ into RetroArch's own core directory
    # (libretro_directory in retroarch.cfg), not just a fixed whitelist of
    # EMULATOR_CORES package ids. This used to be a small hardcoded
    # core_so map (one entry per EMULATOR_CORES package) - confirmed live
    # that it silently missed several cores that WERE actually installed
    # (e.g. lr-mgba's mgba_libretro.so for GBA, lr-fbneo's fbneo_libretro.so
    # for arcade) simply because they had no entry in the map, leaving
    # ES-DE's own default emulator command for those systems unable to
    # find a core at all even though one was sitting right there on disk.
    # A libretrocores package dir can (rarely) ship more than one .so - fbneo
    # ships fbneo_libretro.so, and some future core might ship extra
    # variants - so this links every *_libretro.so found in each package
    # dir, not just one per directory.
    local core_dir so_file so_name
    for core_dir in /opt/retropie/libretrocores/*/; do
        [ -d "$core_dir" ] || continue
        for so_file in "$core_dir"*_libretro.so; do
            [ -f "$so_file" ] || continue
            so_name="$(basename "$so_file")"
            ln -sf "$so_file" "$PI_HOME/.config/retroarch/cores/$so_name"
        done
    done

    # RetroPie's lr-mame ships as mamearcade_libretro.so; ES-DE's find-rules
    # expect mame_libretro.so.
    local mame_src="/opt/retropie/libretrocores/lr-mame/mamearcade_libretro.so"
    if [ -f "$mame_src" ]; then
        ln -sf "$mame_src" "$PI_HOME/.config/retroarch/cores/mame_libretro.so"
    else
        log_warn "mamearcade_libretro.so not found; MAME may not be picked up by ES-DE yet"
    fi

    log "Symlinked $(find "$PI_HOME/.config/retroarch/cores" -maxdepth 1 -name '*_libretro.so' | wc -l) libretro core(s) from /opt/retropie/libretrocores into ~/.config/retroarch/cores"
    return 0
}

# ES-DE's built-in es_systems.xml lists a fixed FIRST <command> as the
# default emulator for each system - and for several systems, that default
# names a core this project doesn't (or can't reliably) install, even
# though a perfectly good alternative core for the same system IS
# installed. Originally found for nes/fds (default "Mesen", requires
# lr-mesen - no aarch64 binary exists for it on this Debian release, nor
# for lr-fceumm; retropie_packages.sh's _binary_ mode exits 0 with just an
# "Errors: Could not find a binary for ..." line rather than failing, so
# this is easy to miss). The exact same class of bug was later confirmed
# live for two more systems: psx (default "Beetle PSX", requires
# mednafen_psx_libretro.so - not in EMULATOR_CORES at all, where PCSX
# ReARMed already is and works) and n64 (default "Mupen64Plus-Next",
# requires mupen64plus_next_libretro.so - EMULATOR_CORES installs the
# *standalone* Mupen64Plus package by default instead, since the libretro
# core has a history of being flaky to build from source here - see the
# README's Known limitations). Left alone, every ROM on an affected system
# fails with "Couldn't find emulator core '<SOMETHING>_LIBRETRO.SO'" even
# though a working core for that exact system is sitting right there.
#
# Fixed the same way for every affected system: pre-seed that system's
# gamelist.xml with the <alternativeEmulator> tag ES-DE's own "Alternative
# Emulators" menu would otherwise write, pointing at whichever ALREADY-
# INSTALLED core/label this project actually provides for it. This only
# sets the system-wide default and does not touch per-game overrides or
# overwrite an existing gamelist.xml.
#
# IMPORTANT: per ES-DE's own GamelistFileParser.cpp (confirmed against the
# actual source this build compiles), <alternativeEmulator> is read via
# doc.child("alternativeEmulator") - i.e. it must be a document-level
# SIBLING of <gameList>, immediately before it - NOT nested inside
# <gameList> as a child. Nesting it inside <gameList> parses without error
# but is silently never read, so the system-wide override has no effect
# and every ROM keeps launching with the (missing) default core - confirmed
# live: this was the actual reason the first version of this fix (for nes/
# fds) didn't work even after a reboot.
#
# Every OTHER system this project installs a core for (snes, psx via PCSX
# ReARMed as set below, psp, gb/gbc, genesis/megadrive, arcade/mame,
# dreamcast) already has ES-DE's own default pointing at the exact core
# this project installs, confirmed by cross-referencing the linuxarm
# es_systems.xml's first <command> per system against phase_emulators_
# install's EMULATOR_CORES and phase_esde_retroarch_links' now-general
# core symlinking - so no override is needed for those, and none is
# applied here.
phase_esde_default_emulators() {
    declare -A default_label=(
        [nes]="Nestopia UE"
        [fds]="Nestopia UE"
        [psx]="PCSX ReARMed"
        [n64]="Mupen64Plus (Standalone)"
    )
    declare -A default_reason=(
        [nes]="Mesen has no aarch64 binary yet"
        [fds]="Mesen has no aarch64 binary yet"
        [psx]="Beetle PSX (mednafen_psx) isn't installed by this project - PCSX ReARMed is"
        [n64]="EMULATOR_CORES installs standalone Mupen64Plus by default, not the lr-mupen64plus-next libretro core"
    )
    local sys label
    for sys in "${!default_label[@]}"; do
        label="${default_label[$sys]}"
        local gl_dir="$PI_HOME/ES-DE/gamelists/$sys"
        local gl_file="$gl_dir/gamelist.xml"
        mkdir -p "$gl_dir"
        chown "$PI_USER:$PI_USER" "$gl_dir" 2>/dev/null || true
        if [ -f "$gl_file" ]; then
            if grep -q '<alternativeEmulator>' "$gl_file"; then
                log "$sys gamelist.xml already has an alternativeEmulator override, leaving as-is"
                continue
            fi
            sed -i "0,/<gameList>/s//<alternativeEmulator>\n\t<label>${label}<\/label>\n<\/alternativeEmulator>\n<gameList>/" "$gl_file" \
                || log_warn "could not patch existing $sys gamelist.xml with alternativeEmulator override"
        else
            cat > "$gl_file" <<EOF
<?xml version="1.0"?>
<alternativeEmulator>
	<label>${label}</label>
</alternativeEmulator>
<gameList>
</gameList>
EOF
        fi
        chown "$PI_USER:$PI_USER" "$gl_file" 2>/dev/null || true
        log "Set $label as the default emulator for $sys (${default_reason[$sys]})"
    done
    return 0
}

phase_themes_install() {
    if [ "$INSTALL_THEMES" != "true" ]; then
        log "INSTALL_THEMES=false, skipping"
        return 0
    fi
    mkdir -p "$PI_HOME/ES-DE/themes"
    cd "$PI_HOME/ES-DE/themes" || die "cannot cd into ES-DE themes dir"
    declare -A theme_repos=(
        [artflix-revisited]="https://github.com/TheGrizzMD/artflix-revisited-es-de.git"
        [art-book-next]="https://github.com/anthonycaccese/art-book-next-es-de.git"
        [alekfull-nx]="https://github.com/anthonycaccese/alekfull-nx-es-de.git"
    )
    local theme_name
    for theme_name in "${!theme_repos[@]}"; do
        if [ ! -d "$theme_name" ]; then
            git clone --depth=1 "${theme_repos[$theme_name]}" "$theme_name" || log_warn "Failed to clone theme $theme_name"
        fi
    done
    return 0
}

# Per-system art for the custom "RetroPie Setup" system, so it doesn't
# render as plain text in each theme's carousel. These are the actual
# curated assets from the reference build (section 14.5) - logos,
# metadata, and backgrounds for each theme - bundled in this repo under
# theme-art/ and downloaded into place here, rather than generated.
phase_theme_system_art() {
    if [ "$INSTALL_THEMES" != "true" ]; then
        return 0
    fi
    local assets_base="https://raw.githubusercontent.com/Cr4zySh4rk/pi-arcade-setup/main/theme-art"
    local themes_dir="$PI_HOME/ES-DE/themes"
    local variant

    _fetch_asset() {
        local url="$1" dest="$2"
        mkdir -p "$(dirname "$dest")"
        curl -fsSL "$url" -o "$dest" || log_warn "Could not download theme art asset: $url"
    }

    if [ -d "$themes_dir/artflix-revisited" ]; then
        _fetch_asset "$assets_base/artflix-revisited/fanart_retropie.jpg" "$themes_dir/artflix-revisited/_inc/systems/fanart/retropie.jpg"
        _fetch_asset "$assets_base/artflix-revisited/logos_retropie.png" "$themes_dir/artflix-revisited/_inc/systems/logos/retropie.png"
        _fetch_asset "$assets_base/artflix-revisited/metadata-global_retropie.xml" "$themes_dir/artflix-revisited/_inc/systems/metadata-global/retropie.xml"
    fi
    if [ -d "$themes_dir/art-book-next" ]; then
        _fetch_asset "$assets_base/art-book-next/logos_retropie.svg" "$themes_dir/art-book-next/_inc/systems/logos/retropie.svg"
        _fetch_asset "$assets_base/art-book-next/_metadata-global_retropie.xml" "$themes_dir/art-book-next/_inc/systems/_metadata-global/retropie.xml"
        for variant in artwork artwork-outline artwork-circuit artwork-noir artwork-screenshots; do
            _fetch_asset "$assets_base/art-book-next/${variant}_retropie.png" "$themes_dir/art-book-next/_inc/systems/$variant/retropie.png"
        done
    fi
    if [ -d "$themes_dir/alekfull-nx" ]; then
        _fetch_asset "$assets_base/alekfull-nx/logos_retropie.svg" "$themes_dir/alekfull-nx/_inc/systems/logos/retropie.svg"
        _fetch_asset "$assets_base/alekfull-nx/backgrounds_retropie.jpg" "$themes_dir/alekfull-nx/_inc/systems/backgrounds/retropie.jpg"
        _fetch_asset "$assets_base/alekfull-nx/carousel-icons_retropie.webp" "$themes_dir/alekfull-nx/_inc/systems/carousel-icons/retropie.webp"
    fi
    log "Installed reference per-theme art for the custom RetroPie system"
    return 0
}

phase_autostart_setup() {
    local esde_rotate_flag=""
    local classic_args="--screensize 1280 800"
    if [ "$ENABLE_DSI_DISPLAY" = "true" ]; then
        esde_rotate_flag="--screenrotate $ESDE_SCREENROTATE"
        classic_args="--screenrotate $CLASSIC_ES_SCREENROTATE --screensize $CLASSIC_ES_SCREENSIZE"
    else
        classic_args=""
    fi

    sudo tee /opt/retropie/configs/all/autostart.sh >/dev/null <<EOF
#!/bin/bash
# Frontend switcher: $PI_HOME/.frontend contains either "esde" or "classic"
# Generated by pi-arcade-setup - see https://github.com/Cr4zySh4rk/pi-arcade-setup
FRONTEND=\$(cat $PI_HOME/.frontend 2>/dev/null || echo classic)
if [ "\$FRONTEND" = "esde" ]; then
    while true; do
        rm -f $PI_HOME/.frontend-switch
        XDG_RUNTIME_DIR=/run/user/\$(id -u $PI_USER) /opt/es-de/bin/es-de $esde_rotate_flag

        [ -f $PI_HOME/.frontend-switch ] && break
        CURRENT=\$(cat $PI_HOME/.frontend 2>/dev/null || echo esde)
        [ "\$CURRENT" != "esde" ] && break

        LOG_TAIL=\$(tail -n 5 $PI_HOME/ES-DE/logs/es_log.txt 2>/dev/null)

        if echo "\$LOG_TAIL" | grep -q 'Restarting ES-DE'; then
            continue
        fi

        # ES-DE's own Reboot/Power Off menu actions run "shutdown --reboot
        # now"/"shutdown --poweroff now" internally via a plain system()
        # call whose result is never checked or surfaced anywhere (not in
        # the UI, not in the log) - if it doesn't fire for any reason, the
        # only visible symptom is ES-DE quitting to this console with the
        # Pi otherwise untouched. The two LOG(LogInfo) lines below it logs
        # right beforehand are unconditional though, so treat them as the
        # actual "user asked for this" signal and issue the real command
        # ourselves too - harmless if ES-DE's own call already succeeded
        # (a second shutdown/reboot request while one is in flight is a
        # no-op), and it's what actually guarantees the Pi does what the
        # menu said regardless of why ES-DE's own attempt may not have.
        if echo "\$LOG_TAIL" | grep -q 'Powering off system'; then
            echo "ES-DE requested power off - issuing shutdown --poweroff now"
            /usr/sbin/shutdown --poweroff now 2>/dev/null || sudo -n /usr/sbin/shutdown --poweroff now 2>/dev/null || true
        elif echo "\$LOG_TAIL" | grep -q 'Rebooting system'; then
            echo "ES-DE requested reboot - issuing shutdown --reboot now"
            /usr/sbin/shutdown --reboot now 2>/dev/null || sudo -n /usr/sbin/shutdown --reboot now 2>/dev/null || true
        fi

        if echo "\$LOG_TAIL" | grep -q 'ES-DE cleanly shutting down'; then
            echo "ES-DE exited cleanly (quit/reboot/power off). Not relaunching."
            echo "Run 'esde' or reboot to return to the frontend."
            break
        fi
    done
else
    emulationstation $classic_args #auto
fi
EOF
    sudo chmod +x /opt/retropie/configs/all/autostart.sh

    tee "$PI_HOME/switch-frontend.sh" >/dev/null <<EOF
#!/bin/bash
# Usage: ./switch-frontend.sh [esde|classic]
if [ "\$1" != "esde" ] && [ "\$1" != "classic" ]; then
    echo "Usage: \$0 [esde|classic]"
    echo "Current: \$(cat $PI_HOME/.frontend 2>/dev/null || echo classic)"
    exit 1
fi
echo "\$1" > $PI_HOME/.frontend
touch $PI_HOME/.frontend-switch
echo "Frontend set to: \$1 (takes effect on next boot/restart)"
EOF
    chmod +x "$PI_HOME/switch-frontend.sh"

    sudo tee /usr/local/bin/esde >/dev/null <<EOF
#!/bin/bash
XDG_RUNTIME_DIR=/run/user/\$(id -u $PI_USER) exec /opt/es-de/bin/es-de $esde_rotate_flag
EOF
    sudo chmod +x /usr/local/bin/esde

    if [ ! -f "$PI_HOME/.frontend" ]; then
        echo "$INITIAL_FRONTEND" > "$PI_HOME/.frontend"
    fi

    if [ "$ENABLE_CONSOLE_AUTOSTART" = "true" ]; then
        # `retropie_packages.sh setup basic_install` does NOT wire up boot
        # autostart on its own - that's a separate, optional RetroPie
        # module ("autostart") that's normally only enabled by hand via the
        # RetroPie-Setup menu. Its enable_autostart function does two
        # things (replicated here, matching its own scriptmodule source at
        # RetroPie-Setup/scriptmodules/supplementary/autostart.sh):
        #   1. `raspi-config nonint do_boot_behaviour B2` - console autologin
        #   2. /etc/profile.d/10-retropie.sh - the actual trigger that runs
        #      autostart.sh on tty1 login (not ~/.bashrc, despite older
        #      documentation/folklore describing it that way).
        # Without this, the box boots to a plain login prompt and nothing
        # ever launches the frontend.
        if [ "$IS_RASPBERRY_PI" = "true" ] && command -v raspi-config >/dev/null 2>&1; then
            sudo raspi-config nonint do_boot_behaviour B2 || log_warn "Could not set console autologin via raspi-config"
        else
            # Generic Debian equivalent of raspi-config's B2 (console
            # autologin): a systemd getty@tty1 drop-in that adds --autologin
            # <user> to agetty's own invocation, plus making sure the box
            # actually boots to a plain text console (multi-user.target, not
            # a graphical target) so tty1 is what's active at boot. This is
            # the standard systemd-native way to do this on any Debian-based
            # box - raspi-config's own do_boot_behaviour does effectively
            # the same drop-in-file mechanism under the hood on Bookworm+
            # anyway, just via its own codepath - not something that only
            # works because it's a Pi. NOT physically verified on non-Pi
            # hardware; report an issue if this doesn't take effect on real
            # hardware.
            sudo systemctl set-default multi-user.target 2>/dev/null || log_warn "Could not set default systemd target to multi-user.target"
            sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
            sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<AUTOEOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $PI_USER --noclear %I \$TERM
AUTOEOF
            sudo systemctl daemon-reload 2>/dev/null || true
            sudo systemctl enable getty@tty1.service >/dev/null 2>&1 || log_warn "Could not enable getty@tty1.service"
            log "Console autologin configured via a systemd getty@tty1 drop-in (generic Debian path, not raspi-config)"
        fi
        sudo rm -f /etc/profile.d/10-emulationstation.sh
        sudo tee /etc/profile.d/10-retropie.sh >/dev/null <<PROFEOF
# launch our autostart apps (if we are on the correct tty and not in X)
if [ "\`tty\`" = "/dev/tty1" ] && [ -z "\$DISPLAY" ] && [ "\$USER" = "$PI_USER" ]; then
    bash "/opt/retropie/configs/all/autostart.sh"
fi
PROFEOF
        log "Console autologin + boot autostart trigger enabled for $PI_USER"
    fi
    return 0
}

phase_custom_retropie_system() {
    mkdir -p "$PI_HOME/ES-DE/custom_systems" "$PI_HOME/ES-DE/gamelists/retropie"

    local keep=(showip.rp avsettings.rp wifigate.rp ftpsettings.rp retroarch.rp)
    [ "$ENABLE_BT_SPEAKER" = "true" ] && keep+=(btpair.rp btaudio.rp)
    [ "$ENABLE_MUSIC_PLAYER" = "true" ] && keep+=(musicplayer.rp)
    [ "$ENABLE_LED_STRIP" = "true" ] && keep+=(ledconfig.rp)

    # RetroPie-Setup's own basic_install seeds this same directory with a
    # full set of classic-EmulationStation menu stub files (filemanager.rp,
    # raspiconfig.rp, retroarch.rp, runcommand.rp, esthemes.rp,
    # splashscreen.rp, retronetplay.rp, rpsetup.rp, wifi.rp, bluetooth.rp,
    # configedit.rp, and more depending on version) - this custom ES-DE
    # system points at that same directory with the same .rp extension, so
    # any of those (or a file left over from an earlier run of this script
    # under an old name, e.g. this tool's own audiosettings.rp before it
    # was renamed to avsettings.rp) can get silently picked up by ES-DE's
    # own gamelist scanner and added to the menu as a bare, undescribed
    # entry - even though it was never in the curated gamelist.xml below.
    # Delete anything in the directory that isn't one of this build's own
    # tools so that can't happen; this runs every time this phase runs, so
    # a rename here (like avsettings.rp's own history) cleans up after
    # itself on the next re-run too.
    if [ -d "$PI_HOME/RetroPie/retropiemenu" ]; then
        local f base found k
        for f in "$PI_HOME"/RetroPie/retropiemenu/*.rp; do
            [ -e "$f" ] || continue
            base="$(basename "$f")"
            found=false
            for k in "${keep[@]}"; do
                if [ "$base" = "$k" ]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                rm -f "$f"
                log "removed stray/obsolete RetroPie menu stub: $base"
            fi
        done
    fi

    tee "$PI_HOME/ES-DE/custom_systems/es_systems.xml" >/dev/null <<EOF
<?xml version="1.0"?>
<systemList>
    <system>
        <name>retropie</name>
        <fullname>RetroPie Setup</fullname>
        <path>$PI_HOME/RetroPie/retropiemenu</path>
        <extension>.rp .sh</extension>
        <command>sudo openvt -c 2 -s -w -f -- env TERM=linux $PI_HOME/RetroPie-Setup/retropie_packages.sh retropiemenu launch %ROM%</command>
        <platform>ignore</platform>
        <theme>retropie</theme>
    </system>
</systemList>
EOF

    local icon_dir="$PI_HOME/RetroPie/retropiemenu/icons"
    tee "$PI_HOME/ES-DE/gamelists/retropie/gamelist.xml" >/dev/null <<EOF
<?xml version="1.0"?>
<gameList>
	<game>
		<path>./showip.rp</path>
		<name>Show IP</name>
		<desc>Displays your current IP address and other network information.</desc>
		<image>$icon_dir/showip.png</image>
	</game>
	<game>
		<path>./retroarch.rp</path>
		<name>RetroArch</name>
		<desc>Opens RetroArch's own configuration menu (RGUI) directly - video, audio, input, and per-core settings, same as classic EmulationStation's RetroArch entry.</desc>
		<image>$icon_dir/configedit.png</image>
	</game>
$( [ "$ENABLE_BT_SPEAKER" = "true" ] && cat <<BTPAIR
	<game>
		<path>./btpair.rp</path>
		<name>Bluetooth</name>
		<desc>Scan for and pair wireless controllers (or any Bluetooth device) - just select one and press confirm, pairing is accepted automatically.</desc>
		<image>$icon_dir/bluetooth.png</image>
	</game>
BTPAIR
)
$( [ "$ENABLE_MUSIC_PLAYER" = "true" ] && cat <<MUSICPLAYER
	<game>
		<path>./musicplayer.rp</path>
		<name>Audio Player</name>
		<desc>Browse and play music from $MUSIC_DIR. Shows the current track, artist, and progress, fully controllable with the controller.</desc>
		<image>$icon_dir/audiosettings.png</image>
	</game>
MUSICPLAYER
)
$( [ "$ENABLE_BT_SPEAKER" = "true" ] && cat <<BTAUDIO
	<game>
		<path>./btaudio.rp</path>
		<name>Bluetooth Player</name>
		<desc>Pair a device to "$BT_SPEAKER_NAME" and stream music to the arcade's speakers. Shows the connected device's now-playing track, car-stereo style, and lets the controller play/pause/skip.</desc>
		<image>$icon_dir/bluetooth.png</image>
	</game>
BTAUDIO
)
$( [ "$ENABLE_LED_STRIP" = "true" ] && cat <<LEDCFG
	<game>
		<path>./ledconfig.rp</path>
		<name>LED Config</name>
		<desc>Set the LED strip's mode (solid, flash, breathe, wave, rainbow, chase, theater_chase, bounce, color_wipe, sparkle, confetti, fire), color, brightness, animation speed, and live LED count.</desc>
		<image>$icon_dir/configedit.png</image>
	</game>
LEDCFG
)
	<game>
		<path>./wifigate.rp</path>
		<name>Wifi settings</name>
		<desc>Connect to a WiFi network. Asks first whether a keyboard is plugged in (needed to type the network name and password) before opening the configurator.</desc>
		<image>$icon_dir/wifi.png</image>
	</game>
	<game>
		<path>./avsettings.rp</path>
		<name>Audio settings</name>
		<desc>Switch the audio output between the 3.5mm jack and HDMI, and adjust master volume/mute.</desc>
		<image>$icon_dir/audiosettings.png</image>
	</game>
	<game>
		<path>./ftpsettings.rp</path>
		<name>FTP settings</name>
		<desc>Turn FTP and/or SFTP file transfer on or off independently.</desc>
		<image>$icon_dir/filemanager.png</image>
	</game>
$( [ "$ENABLE_BEZEL_PROJECT" = "true" ] && cat <<BEZELPROJECT
	<game>
		<path>./bezelproject.sh</path>
		<name>Bezel Project</name>
		<desc>Browse and download per-system RetroArch overlay bezels (thebezelproject/BezelProject). Read the README's Known limitations note on the arcade/MAME pack before enabling it - it can undo this project's own rotation fix for that system.</desc>
		<image>$icon_dir/configedit.png</image>
	</game>
BEZELPROJECT
)
</gameList>
EOF

    # RetroPie-Setup's own retropiemenu.sh ships a "retroarch.rp" case
    # (opens RetroArch's own RGUI settings menu directly, no ROM loaded -
    # the same entry classic EmulationStation exposes) that this project's
    # custom, deliberately-lean menu system doesn't wire up by default (see
    # the "keep" list above and the step 15 README note on what's
    # intentionally left out). Wire it back in - it's a genuinely useful
    # escape hatch for anything not exposed by this project's own tools
    # (video/audio/input settings, per-core options, etc.), and costs
    # nothing to have available.
    touch "$PI_HOME/RetroPie/retropiemenu/retroarch.rp"
    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "retroarch.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[retroarch.rp] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[retroarch.rp] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
body_indent = indent + "    "
insert_block = (
    f"{indent}retroarch.rp)\n"
    f'{body_indent}joy2keyStop\n'
    f'{body_indent}cp "$configdir/all/retroarch.cfg" "$configdir/all/retroarch.cfg.bak"\n'
    f'{body_indent}chown "$__user":"$__group" "$configdir/all/retroarch.cfg.bak"\n'
    f'{body_indent}su "$__user" -c "XDG_RUNTIME_DIR=/run/user/$SUDO_UID \\"$emudir/retroarch/bin/retroarch\\" --menu --config \\"$configdir/all/retroarch.cfg\\""\n'
    f'{body_indent}iniConfig " = " \'"\' "$configdir/all/retroarch.cfg"\n'
    f'{body_indent}iniSet "config_save_on_exit" "false"\n'
    f"{indent}    ;;\n"
)
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[retroarch.rp] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_splash_setup() {
    if [ "$ENABLE_DSI_DISPLAY" = "true" ] && [ -n "$SPLASH_TRANSFORM_TYPE" ]; then
        sudo tee /opt/retropie/configs/all/splashscreen.cfg >/dev/null <<EOF
RANDOMIZE="disabled" CMD_OPTS="--video-filter=transform --transform-type=$SPLASH_TRANSFORM_TYPE"
EOF
    fi
    if [ -n "$SPLASH_VIDEO_URL" ]; then
        mkdir -p "$PI_HOME/RetroPie/splashscreens"
        local dest="$PI_HOME/RetroPie/splashscreens/custom-retro-splash.mp4"
        if curl -fsSL "$SPLASH_VIDEO_URL" -o "$dest"; then
            sudo chown "$PI_USER":"$PI_USER" "$dest"
            echo "$dest" | sudo tee /etc/splashscreen.list >/dev/null
            log "Custom splash video installed from $SPLASH_VIDEO_URL (rotation is baked into the file - see SPLASH_VIDEO_URL comment above)"
        else
            log_warn "Failed to download splash video from $SPLASH_VIDEO_URL; leaving stock splash in place"
        fi
    fi
    sudo systemctl is-enabled asplashscreen.service >/dev/null 2>&1 || log_warn "asplashscreen.service not enabled; splash screen may not run at boot"
    return 0
}

phase_polkit_fix() {
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/50-pi-power.rules >/dev/null <<EOF
// Allow the $PI_USER user to reboot/power off/suspend without an
// authentication agent (headless kiosk-style RetroPie/ES-DE setup).
// Generated by pi-arcade-setup.
polkit.addRule(function(action, subject) {
    var powerActions = [
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.suspend-multiple-sessions"
    ];
    if (powerActions.indexOf(action.id) !== -1 && subject.user == "$PI_USER") {
        return polkit.Result.YES;
    }
});
EOF
    sudo chmod 644 /etc/polkit-1/rules.d/50-pi-power.rules
    sudo systemctl restart polkit || log_warn "Could not restart polkit; reboot to apply the power-action rule"
    return 0
}

phase_led_strip_setup() {
    if [ "$ENABLE_LED_STRIP" != "true" ]; then
        log "ENABLE_LED_STRIP=false, skipping"
        return 0
    fi
    if [ "$IS_RASPBERRY_PI" != "true" ]; then
        log_warn "ENABLE_LED_STRIP=true but IS_RASPBERRY_PI=false - rpi_ws281x drives the strip via the BCM SoC's own PWM/PCM peripheral + DMA, which doesn't exist on non-Pi hardware. Skipping; a different board would need its own GPIO/LED library wired in here instead."
        return 0
    fi
    # rpi_ws281x is the standard hardware-DMA-timed WS2812 driver for the
    # Pi - the direct equivalent of what WLED itself relies on (ESP32's RMT
    # peripheral + DMA) rather than software bit-banging. It only works on
    # the specific GPIOs wired to the SoC's PWM/PCM/SPI0 peripherals: 12,
    # 13, 18, 19 (PWM), 21 (PCM), or 10 (SPI0 MOSI) - LED_GPIO_PIN must be
    # one of these. An earlier version of this phase bit-banged GPIO4
    # directly via pigpio/a custom C driver since that's where the
    # reference build's strip was originally wired; that approach was
    # dropped after live testing showed it was unreliable (confirmed
    # root cause: GPIO4 has no PWM/PCM/SPI alternate function on the
    # BCM2711 at all, so there's no hardware timing assist available for
    # it, matching why WLED itself never bit-bangs this in software either).
    # Installed for root specifically since led-strip.service runs as root
    # (rpi_ws281x needs /dev/mem for DMA + clock manager access, not just
    # /dev/gpiomem).
    sudo python3 -m pip install rpi_ws281x --break-system-packages --root-user-action=ignore \
        || { log_warn "rpi_ws281x install failed; skipping LED strip setup"; return 0; }

    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/led-strip.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
WS2812B addressable LED strip daemon for pi-arcade-setup
(https://github.com/Cr4zySh4rk/pi-arcade-setup).

Drives the strip via rpi_ws281x, which uses the Pi's PWM/PCM peripheral +
DMA to generate hardware-timed pulses - the same class of approach WLED
itself uses on ESP32 (its RMT peripheral + DMA), rather than a CPU busy-loop
bit-bang. This only works on GPIO$LED_GPIO_PIN because that's one of the
few pins actually wired to that peripheral in silicon (12/13/18/19 for PWM,
21 for PCM, 10 for SPI0 MOSI) - see the comment in phase_led_strip_setup in
install.sh if you need to use a different pin.

Reads the live effect config from CONFIG_FILE, written by the in-frontend
"LED Config" tool (led-config.py) - polls it every frame (cheap mtime
check) so color/brightness/speed/mode changes apply immediately, live,
while led-config.py is open.
"""
import colorsys
import json
import math
import os
import random
import time

from rpi_ws281x import Color, PixelStrip

GPIO = $LED_GPIO_PIN
LED_COUNT_MAX = $LED_COUNT_MAX  # strip is always allocated at this size - see connect()
LED_FREQ_HZ = 800000
LED_DMA_CHANNEL = $LED_DMA_CHANNEL
LED_CHANNEL = $LED_PWM_CHANNEL
LED_INVERT = False
CONFIG_FILE = "$PI_HOME/.led-strip-config.json"
FPS = 40

DEFAULT_CONFIG = {"power": True, "mode": "rainbow", "color": [255, 60, 0], "brightness": 70, "speed": 50, "led_count": $LED_COUNT}


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def scale(rgb, pct):
    f = clamp(pct, 0, 100) / 100.0
    return tuple(int(clamp(c, 0, 255) * f) for c in rgb)


def connect():
    # Always allocate for LED_COUNT_MAX, regardless of the *live* led_count
    # in the config - rpi_ws281x needs its DMA buffer sized upfront and
    # can't be resized on a running strip, so growing/shrinking led_count
    # from the LED Config tool just changes how many of these pre-allocated
    # pixels get lit each frame (see main()), with no restart needed.
    #
    # LED_BRIGHTNESS is fixed at 255 here - brightness is applied ourselves
    # per-pixel in scale() instead, so the effect config's brightness value
    # (0-100) is the single source of truth rather than fighting with the
    # library's own separate brightness knob.
    strip = PixelStrip(LED_COUNT_MAX, GPIO, LED_FREQ_HZ, LED_DMA_CHANNEL, LED_INVERT, 255, LED_CHANNEL)
    strip.begin()
    return strip


def show(strip, pixels, live_count):
    for i in range(LED_COUNT_MAX):
        if i < live_count:
            r, g, b = pixels[i]
        else:
            r, g, b = (0, 0, 0)  # blank out anything beyond the current live count
        strip.setPixelColor(i, Color(int(clamp(r, 0, 255)), int(clamp(g, 0, 255)), int(clamp(b, 0, 255))))
    strip.show()


_last_mtime = None
_cached_cfg = dict(DEFAULT_CONFIG)


def load_config():
    global _last_mtime, _cached_cfg
    try:
        mtime = os.path.getmtime(CONFIG_FILE)
    except OSError:
        return _cached_cfg
    if mtime != _last_mtime:
        try:
            with open(CONFIG_FILE) as f:
                data = json.load(f)
            cfg = dict(DEFAULT_CONFIG)
            cfg.update(data)
            _cached_cfg = cfg
            _last_mtime = mtime
        except Exception:
            pass
    return _cached_cfg


def render(mode, color, brightness, speed, t, led_count):
    n = clamp(led_count, 1, LED_COUNT_MAX)
    speed_f = clamp(speed, 0, 100) / 100.0

    if mode == "off":
        return [(0, 0, 0)] * n

    if mode == "solid":
        return [scale(color, brightness)] * n

    if mode == "flash":
        period = 1.4 - speed_f * 1.2  # 1.4s (slow) .. 0.2s (fast)
        on = (t % period) < (period / 2)
        return [scale(color, brightness) if on else (0, 0, 0)] * n

    if mode == "breathe":
        rate = 0.15 + speed_f * 1.35  # Hz
        level = (math.sin(t * rate * 2 * math.pi) + 1) / 2
        return [scale(color, brightness * level)] * n

    if mode == "wave":
        rate = 0.2 + speed_f * 2.3
        pixels = []
        for i in range(n):
            phase = (i / max(1, n - 1)) * 2 * math.pi * 2 - t * rate * 2 * math.pi
            level = (math.sin(phase) + 1) / 2
            pixels.append(scale(color, brightness * (0.15 + 0.85 * level)))
        return pixels

    if mode == "rainbow":
        rate = 0.05 + speed_f * 0.6
        pixels = []
        for i in range(n):
            hue = ((i / n) + t * rate) % 1.0
            r, g, b = colorsys.hsv_to_rgb(hue, 1.0, 1.0)
            pixels.append(scale((int(r * 255), int(g * 255), int(b * 255)), brightness))
        return pixels

    if mode == "chase":
        rate = 1.0 + speed_f * 14.0  # pixels/sec
        tail = max(2, n // 4)
        pos = (t * rate) % n
        pixels = []
        for i in range(n):
            d = (pos - i) % n
            level = 1.0 - (d / tail) if d < tail else 0.0
            pixels.append(scale(color, brightness * level))
        return pixels

    if mode == "theater_chase":
        # Classic marquee pattern: every 3rd pixel lit, the lit group
        # shifting by one pixel per step.
        rate = 2.0 + speed_f * 14.0  # steps/sec
        step = int(t * rate) % 3
        return [scale(color, brightness) if (i % 3 == step) else (0, 0, 0) for i in range(n)]

    if mode == "bounce":
        # A soft-edged lit segment ("Cylon"/Larson-scanner eye) sweeps back
        # and forth between the two ends of the strip.
        rate = 0.3 + speed_f * 3.2  # sweeps/sec across the full strip
        span = max(1, n - 1)
        # triangle wave 0..1..0 over one period, mapped across the strip
        phase = (t * rate) % 2.0
        frac = phase if phase <= 1.0 else 2.0 - phase
        pos = frac * span
        tail = max(1.5, n / 6)
        pixels = []
        for i in range(n):
            d = abs(pos - i)
            level = max(0.0, 1.0 - d / tail)
            pixels.append(scale(color, brightness * level))
        return pixels

    if mode == "color_wipe":
        # Fills the strip outward from the center in the chosen color, then
        # empties back down to the center the same way, looping.
        rate = 3.0 + speed_f * 30.0  # pixels/sec
        center = (n - 1) / 2.0
        # +1 so the growing radius fully reaches (and clears) the end pixels
        # even when the center falls between two LEDs (even LED counts).
        max_radius = max(center, (n - 1) - center) + 1
        cycle = 2 * max_radius
        pos = (t * rate) % cycle
        radius = pos if pos < max_radius else cycle - pos
        pixels = []
        for i in range(n):
            on = abs(i - center) <= radius
            pixels.append(scale(color, brightness) if on else (0, 0, 0))
        return pixels

    if mode == "sparkle":
        # Random pixels in the chosen color flash briefly against black.
        # Reseeded on each discrete "tick" (not every frame) so a given
        # instant looks the same across the couple of frames it spans,
        # instead of pure per-frame noise.
        rate = 4.0 + speed_f * 46.0  # ticks/sec
        tick = int(t * rate)
        rng = random.Random(tick)
        density = 0.06 + speed_f * 0.10
        pixels = []
        for i in range(n):
            lit = rng.random() < density
            pixels.append(scale(color, brightness) if lit else (0, 0, 0))
        return pixels

    if mode == "confetti":
        # Like sparkle, but each spark gets its own random hue instead of
        # the configured color - livelier/more colorful.
        rate = 4.0 + speed_f * 46.0
        tick = int(t * rate)
        rng = random.Random(tick * 7919 + 1)  # different stream than sparkle
        density = 0.06 + speed_f * 0.10
        pixels = []
        for i in range(n):
            if rng.random() < density:
                hue = rng.random()
                r, g, b = colorsys.hsv_to_rgb(hue, 1.0, 1.0)
                pixels.append(scale((int(r * 255), int(g * 255), int(b * 255)), brightness))
            else:
                pixels.append((0, 0, 0))
        return pixels

    if mode == "fire":
        # Lightweight flicker-fire simulation: a warm red/orange/yellow
        # ramp per pixel, with brightness driven by overlapping sine waves
        # (smooth flicker) plus light per-pixel randomness (crackle),
        # hottest at the strip's center and cooler toward both ends.
        # Ignores the configured color - like rainbow, fire has its own
        # fixed palette.
        rate = 2.0 + speed_f * 10.0
        rng = random.Random(int(t * 30))  # coarse tick so crackle doesn't strobe every frame
        center = (n - 1) / 2.0
        max_dist = max(center, (n - 1) - center) or 1
        pixels = []
        for i in range(n):
            dist = abs(i - center)
            base = 1.0 - (dist / max_dist) * 0.55  # hotter near the center
            flicker = (
                math.sin(t * rate * 2 * math.pi + i * 0.9) * 0.2
                + math.sin(t * rate * 4.3 * math.pi + i * 2.1) * 0.12
            )
            crackle = (rng.random() - 0.5) * 0.25
            heat = clamp(base + flicker + crackle, 0.0, 1.0)
            # heat -> color ramp: black -> red -> orange -> yellow
            r = clamp(heat * 3.0, 0.0, 1.0)
            g = clamp(heat * 3.0 - 1.0, 0.0, 1.0)
            b = clamp(heat * 3.0 - 2.2, 0.0, 1.0)
            pixels.append(scale((int(r * 255), int(g * 255), int(b * 200)), brightness))
        return pixels

    return [(0, 0, 0)] * n


def main():
    strip = connect()
    print(f"[led-strip] driving up to {LED_COUNT_MAX} LEDs on GPIO{GPIO} via rpi_ws281x (hardware-timed)")
    t0 = time.monotonic()
    try:
        while True:
            cfg = load_config()
            live_count = clamp(int(cfg.get("led_count", LED_COUNT_MAX)), 1, LED_COUNT_MAX)
            if not cfg.get("power", True):
                show(strip, [(0, 0, 0)] * live_count, live_count)
                time.sleep(0.2)
                continue
            t = time.monotonic() - t0
            pixels = render(
                cfg.get("mode", "solid"),
                tuple(cfg.get("color", [255, 255, 255])),
                cfg.get("brightness", 70),
                cfg.get("speed", 50),
                t,
                live_count,
            )
            show(strip, pixels, live_count)
            time.sleep(max(0.0, 1.0 / FPS))
    except KeyboardInterrupt:
        pass
    finally:
        try:
            show(strip, [(0, 0, 0)] * LED_COUNT_MAX, LED_COUNT_MAX)
        except Exception:
            pass


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/led-strip.py"

    if [ ! -f "$PI_HOME/.led-strip-config.json" ]; then
        cat > "$PI_HOME/.led-strip-config.json" <<CFGEOF
{"power": true, "mode": "rainbow", "color": [255, 60, 0], "brightness": 70, "speed": 50, "led_count": $LED_COUNT}
CFGEOF
    fi

    sudo tee /etc/systemd/system/led-strip.service >/dev/null <<EOF
[Unit]
Description=WS2812B LED strip daemon (GPIO$LED_GPIO_PIN, rpi_ws281x)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u $PI_HOME/scripts/led-strip.py
Restart=always
RestartSec=2
User=root
StandardOutput=append:/var/log/led-strip.log
StandardError=append:/var/log/led-strip.log

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now led-strip.service
    return 0
}

phase_led_config_tool() {
    if [ "$ENABLE_LED_STRIP" != "true" ]; then
        return 0
    fi
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/led-config.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Interactive LED strip configuration tool for pi-arcade-setup. Run from the
RetroPie menu ("LED Config") or directly:
    sudo python3 led-config.py
Writes live to the config file the led-strip.py daemon polls, so changes
apply to the physical strip immediately while this is open.

Fully navigable by controller as well as keyboard: left stick (or D-pad, on
controllers that report it as an axis) to move/adjust, X/Cross to confirm,
Circle/B to exit - same button roles as the rest of the RetroPie menu.
"""
import curses
import json
import os
import select
import struct
import sys
import time

CONFIG_FILE = "$PI_HOME/.led-strip-config.json"
LED_COUNT_MAX = $LED_COUNT_MAX
GPIO = $LED_GPIO_PIN

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000  # out of a signed 16-bit axis range (-32768..32767)
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

MODES = [
    "solid", "flash", "breathe", "wave", "rainbow", "chase",
    "theater_chase", "bounce", "color_wipe", "sparkle", "confetti", "fire",
]
PRESETS = [
    ("Red", (255, 0, 0)), ("Orange", (255, 60, 0)), ("Yellow", (255, 200, 0)),
    ("Green", (0, 255, 0)), ("Cyan", (0, 255, 200)), ("Blue", (0, 80, 255)),
    ("Purple", (160, 0, 255)), ("Pink", (255, 0, 120)), ("White", (255, 255, 255)),
]

DEFAULT_CONFIG = {"power": True, "mode": "rainbow", "color": [255, 60, 0], "brightness": 70, "speed": 50, "led_count": $LED_COUNT}

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD, COL_SEL = 1, 2, 3, 4, 5, 6


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE) as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    cfg["color"] = list(cfg.get("color", DEFAULT_CONFIG["color"]))[:3]
    cfg["led_count"] = clamp(int(cfg.get("led_count", DEFAULT_CONFIG["led_count"])), 1, LED_COUNT_MAX)
    return cfg


def save_config(cfg):
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f)
    except Exception:
        pass


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


ROWS = ["power", "mode", "led_count", "r", "g", "b", "preset", "brightness", "speed"]
ROW_LABELS = {
    "power": "Power", "mode": "Mode", "led_count": "LED count", "r": "Red", "g": "Green", "b": "Blue",
    "preset": "Color preset", "brightness": "Brightness", "speed": "Speed",
}


def draw(win, cfg, sel, preset_idx, js_connected):
    win.erase()
    h, w = win.getmaxyx()
    title = " LED STRIP CONFIGURATION "
    safe_addstr(win, 1, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)
    sub = f"WS2812B on GPIO{GPIO} - up to {LED_COUNT_MAX} LEDs"
    safe_addstr(win, 2, cx(win, sub), sub, curses.A_DIM)

    top = 5
    for i, key in enumerate(ROWS):
        y = top + i
        is_sel = i == sel
        prefix = "> " if is_sel else "  "
        label = f"{prefix}{ROW_LABELS[key]:<14}"
        if key == "power":
            val = "ON" if cfg["power"] else "OFF"
        elif key == "mode":
            val = cfg["mode"].upper()
        elif key == "led_count":
            val = f"{cfg['led_count']:>3} / {LED_COUNT_MAX}"
        elif key == "r":
            val = f"{cfg['color'][0]:>3}"
        elif key == "g":
            val = f"{cfg['color'][1]:>3}"
        elif key == "b":
            val = f"{cfg['color'][2]:>3}"
        elif key == "preset":
            val = PRESETS[preset_idx][0]
        elif key == "brightness":
            val = f"{cfg['brightness']:>3}%"
        elif key == "speed":
            val = f"{cfg['speed']:>3}%"
        attr = (curses.color_pair(COL_SEL) | curses.A_BOLD) if is_sel else curses.color_pair(COL_LABEL)
        col = max(0, (w // 2) - 18)
        safe_addstr(win, y, col, label, attr)
        safe_addstr(win, y, col + 18, val, attr | (curses.A_BOLD if is_sel else 0))

    color_line = f"RGB preview: ({cfg['color'][0]}, {cfg['color'][1]}, {cfg['color'][2]})"
    safe_addstr(win, top + len(ROWS) + 1, cx(win, color_line), color_line, curses.A_DIM)

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, top + len(ROWS) + 2, cx(win, js_line), js_line, curses.color_pair(COL_GOOD if js_connected else COL_BAD) | curses.A_DIM)

    footer1 = "UP/DOWN or stick: select   LEFT/RIGHT or stick: adjust"
    footer2 = "Enter/A/X: apply preset & toggle power   ESC/B/Circle: done - changes save automatically"
    safe_addstr(win, h - 3, cx(win, footer1), footer1, curses.color_pair(COL_HINT))
    safe_addstr(win, h - 2, cx(win, footer2), footer2, curses.A_DIM)
    win.refresh()


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


CONFIRM_DEBOUNCE_S = 0.25
# Guards confirm/back specifically (not directional movement) against
# switch/contact bounce on cheap arcade buttons and joystick encoders, which
# can report two or more rapid press events for what is physically a single
# tap - without this a bounced confirm press on "power" could toggle the LED
# strip on and then immediately back off again, which looks to the user like
# the button "did nothing".


def poll_action(stdscr, js_file, axis_state, action_debounce, timeout=0.08):
    """Blocks up to `timeout` seconds for keyboard or joystick input, and
    returns one of "up"/"down"/"left"/"right"/"confirm"/"back"/None.
    axis_state tracks whether each stick axis is currently past the
    threshold, so a held stick fires once per push rather than repeating
    every poll - it must return to neutral before firing again."""
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        action = "confirm"
                    elif number == BTN_BACK:
                        action = "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch == curses.KEY_LEFT:
            return "left"
        if ch == curses.KEY_RIGHT:
            return "right"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)
    curses.init_pair(COL_SEL, curses.COLOR_GREEN, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    axis_state = {}
    action_debounce = {}

    cfg = load_config()
    sel = 0
    preset_idx = 0
    save_config(cfg)

    try:
        while True:
            draw(stdscr, cfg, sel, preset_idx, js_file is not None)
            action = poll_action(stdscr, js_file, axis_state, action_debounce)
            if action is None:
                continue

            if action == "back":
                break
            elif action == "up":
                sel = (sel - 1) % len(ROWS)
            elif action == "down":
                sel = (sel + 1) % len(ROWS)
            else:
                key = ROWS[sel]
                step_dir = 1 if action == "right" else (-1 if action == "left" else 0)
                if key == "power" and action in ("left", "right", "confirm"):
                    cfg["power"] = not cfg["power"]
                    save_config(cfg)
                elif key == "mode" and step_dir:
                    idx = MODES.index(cfg["mode"]) if cfg["mode"] in MODES else 0
                    cfg["mode"] = MODES[(idx + step_dir) % len(MODES)]
                    save_config(cfg)
                elif key == "led_count" and step_dir:
                    cfg["led_count"] = clamp(cfg["led_count"] + step_dir, 1, LED_COUNT_MAX)
                    save_config(cfg)
                elif key in ("r", "g", "b") and step_dir:
                    i = {"r": 0, "g": 1, "b": 2}[key]
                    cfg["color"][i] = clamp(cfg["color"][i] + step_dir * 5, 0, 255)
                    save_config(cfg)
                elif key == "preset":
                    if step_dir:
                        preset_idx = (preset_idx + step_dir) % len(PRESETS)
                    if action == "confirm" or step_dir:
                        cfg["color"] = list(PRESETS[preset_idx][1])
                        save_config(cfg)
                elif key == "brightness" and step_dir:
                    cfg["brightness"] = clamp(cfg["brightness"] + step_dir * 5, 0, 100)
                    save_config(cfg)
                elif key == "speed" and step_dir:
                    cfg["speed"] = clamp(cfg["speed"] + step_dir * 5, 0, 100)
                    save_config(cfg)
    finally:
        if js_file is not None:
            js_file.close()

    return cfg


def main():
    cfg = curses.wrapper(run)
    save_config(cfg)
    print()
    print("=" * 50)
    print(" LED strip configuration saved:")
    print(f"   Power:      {'ON' if cfg['power'] else 'OFF'}")
    print(f"   Mode:       {cfg['mode']}")
    print(f"   LED count:  {cfg['led_count']}")
    print(f"   Color:      RGB({cfg['color'][0]}, {cfg['color'][1]}, {cfg['color'][2]})")
    print(f"   Brightness: {cfg['brightness']}%")
    print(f"   Speed:      {cfg['speed']}%")
    print("=" * 50)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/led-config.py"

    touch "$PI_HOME/RetroPie/retropiemenu/ledconfig.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "ledconfig.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[ledconfig] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[ledconfig] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}ledconfig.rp)\n{indent}    python3 {pi_home}/scripts/led-config.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[ledconfig] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_audio_output_setup() {
    if [ "$ENABLE_AUX_AUDIO_FORCE" != "true" ]; then
        log "ENABLE_AUX_AUDIO_FORCE=false, skipping"
        return 0
    fi
    # This build drives its display over DSI (no HDMI audio capability), but
    # the Pi's HDMI ports still expose PipeWire/ALSA sinks the moment
    # anything gets plugged into them, and WirePlumber could then pick one
    # as the default output instead of the 3.5mm jack. Pin the aux/
    # headphone sink (the bcm2835 "mailbox" audio interface - the onboard
    # analog jack on every Pi model that has one) as the default via
    # wpctl, which persists the choice by node name (not a reboot-unstable
    # numeric id) across reboots - so this survives even if a monitor with
    # HDMI audio gets connected later.
    local uid
    uid="$(id -u "$PI_USER")"
    sudo -u "$PI_USER" XDG_RUNTIME_DIR="/run/user/$uid" python3 - <<'PYEOF' || log_warn "could not select aux audio output (no headphone sink found?)"
import re
import subprocess
import sys

out = subprocess.run(["wpctl", "status"], capture_output=True, text=True).stdout
in_sinks = False
sink_ids = []
for line in out.splitlines():
    if "Sinks:" in line:
        in_sinks = True
        continue
    if in_sinks:
        if "Sources:" in line:
            break
        m = re.search(r"(\d+)\.\s", line)
        if m:
            sink_ids.append(m.group(1))

target = None
for sid in sink_ids:
    info = subprocess.run(["wpctl", "inspect", sid], capture_output=True, text=True).stdout
    if "mailbox" in info or "bcm2835 Headphones" in info:
        target = sid
        break

if not target:
    print("[audio] no aux/headphone sink found among:", sink_ids, file=sys.stderr)
    sys.exit(1)

subprocess.run(["wpctl", "set-default", target], check=True)
print(f"[audio] default output set to aux/headphone jack (sink {target})")
PYEOF
    return 0
}

phase_music_player_setup() {
    if [ "$ENABLE_MUSIC_PLAYER" != "true" ]; then
        log "ENABLE_MUSIC_PLAYER=false, skipping"
        return 0
    fi
    # Installed system-wide (sudo), not just for the calling user: the
    # RetroPie menu actually launches this tool as root (retropiemenu.sh's
    # dispatch runs under the outer `sudo openvt ...` from the custom
    # system's <command>, regardless of whether the case entry itself says
    # sudo), so a user-local `pip install` here would be invisible to it at
    # runtime even though it works fine when tested directly as the Pi user.
    sudo python3 -m pip install python-vlc mutagen --break-system-packages --root-user-action=ignore \
        || { log_warn "python-vlc/mutagen install failed; skipping Music Player setup"; return 0; }

    mkdir -p "$PI_HOME/scripts" "$MUSIC_DIR"

    # Pre-created (and thus pi-owned) up front - this tool actually runs as
    # root via the RetroPie menu (see the pip-install comment above), and a
    # config file *first created* by a root process would end up root-owned,
    # silently breaking writes if the tool is later also run directly as
    # the Pi user over SSH.
    if [ ! -f "$PI_HOME/.music-player-config.json" ]; then
        cat > "$PI_HOME/.music-player-config.json" <<CFGEOF
{"volume": 70, "last_index": 0}
CFGEOF
    fi

    tee "$PI_HOME/scripts/music-player.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Apple-Music-style local MP3/FLAC/OGG player for pi-arcade-setup. Run from
the RetroPie menu ("Music Player") or directly:
    python3 music-player.py
Plays audio files from MUSIC_DIR via VLC (python-vlc bindings), reading
ID3/FLAC/OGG tags with mutagen when available (falls back to filenames).

Fully navigable by controller as well as keyboard: left stick (or D-pad, on
controllers that report it as an axis) to move/adjust, X/Cross to confirm,
Circle/B to exit - same button roles as the rest of the RetroPie menu.
"""
import curses
import json
import os
import select
import struct
import subprocess
import sys
import time

PI_HOME = "$PI_HOME"
MUSIC_DIR = "$MUSIC_DIR"
CONFIG_FILE = "$PI_HOME/.music-player-config.json"
EXTENSIONS = (".mp3", ".flac", ".ogg", ".oga", ".wav", ".m4a", ".aac", ".wma", ".opus")

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000  # out of a signed 16-bit axis range (-32768..32767)
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

DEFAULT_CONFIG = {"last_index": 0}

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD, COL_SEL, COL_ACCENT = 1, 2, 3, 4, 5, 6, 7

try:
    import vlc
    VLC_AVAILABLE = True
except Exception:
    VLC_AVAILABLE = False

try:
    from mutagen import File as MutagenFile
    MUTAGEN_AVAILABLE = True
except Exception:
    MUTAGEN_AVAILABLE = False


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def cx_in(width, text):
    return max(0, (width - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE) as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    return cfg


def save_config(cfg):
    try:
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f)
    except Exception:
        pass


def _wpctl_env():
    """wpctl talks to the calling user's own PipeWire session over
    $XDG_RUNTIME_DIR - but this tool actually runs as root when launched
    from the RetroPie menu (see the pip-install comment above), which has
    no PipeWire session of its own. Point it at the Pi user's session
    (found via who owns their home directory, not a hardcoded uid) instead
    of whatever - if anything - root's own XDG_RUNTIME_DIR resolves to."""
    env = dict(os.environ)
    try:
        env["XDG_RUNTIME_DIR"] = f"/run/user/{os.stat(PI_HOME).st_uid}"
    except Exception:
        pass
    return env


def get_system_volume():
    """Reads the Pi's actual output volume via wpctl - the same volume the
    hardware brightness/volume hotkeys and every other pi-arcade-setup tool
    control, so what's shown here always matches reality (unlike a
    per-player software volume, which would drift out of sync with the
    hotkeys and not reflect what you actually hear)."""
    try:
        out = subprocess.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
                              capture_output=True, text=True, timeout=2, env=_wpctl_env()).stdout
        parts = out.strip().split()
        if len(parts) >= 2:
            vol = int(round(float(parts[1]) * 100))
            return clamp(vol, 0, 100), "MUTED" in out
    except Exception:
        pass
    return None, False


def set_system_volume_step(step):
    try:
        sign = "+" if step > 0 else "-"
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{abs(step)}%{sign}"],
                        capture_output=True, timeout=2, env=_wpctl_env())
    except Exception:
        pass


def humanize(path):
    base = os.path.splitext(os.path.basename(path))[0]
    base = base.replace("_", " ").replace("-", " - ")
    return " ".join(base.split())


def read_tags(path):
    title, artist, album = humanize(path), "", ""
    if MUTAGEN_AVAILABLE:
        try:
            f = MutagenFile(path, easy=True)
            if f is not None:
                if f.get("title"):
                    title = str(f["title"][0])
                if f.get("artist"):
                    artist = str(f["artist"][0])
                if f.get("album"):
                    album = str(f["album"][0])
        except Exception:
            pass
    return title, artist, album


def scan_library(root):
    tracks = []
    if not os.path.isdir(root):
        return tracks
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.lower().endswith(EXTENSIONS):
                path = os.path.join(dirpath, fn)
                title, artist, album = read_tags(path)
                tracks.append({"path": path, "title": title, "artist": artist, "album": album})
    tracks.sort(key=lambda tr: (tr["artist"].lower(), tr["album"].lower(), tr["title"].lower()))
    return tracks


def fmt_time(ms):
    if ms is None or ms < 0:
        return "--:--"
    s = int(ms / 1000)
    return f"{s // 60:02d}:{s % 60:02d}"


def marquee(text, width, t, speed=3.0):
    if width <= 0:
        return ""
    if len(text) <= width:
        return text.center(width)
    pad = text + "     " + text
    offset = int(t * speed) % (len(text) + 5)
    return pad[offset: offset + width]


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


CONFIRM_DEBOUNCE_S = 0.25
# Guards "confirm"/"back" specifically (not directional movement) against
# switch/contact bounce on cheap arcade buttons and joystick encoders, which
# can report two or more rapid press events for what is physically a single
# tap. Without this, a bounced confirm press toggles play/pause twice in
# quick succession - looking, from the user's side, like the button "did
# nothing" on the second real press (it actually played, paused, and
# resumed all within one press). Directional actions don't need this: they
# already debounce via the axis-crossing edge check below, and repeating
# them on a held button/key is the desired behavior for menu navigation.


def poll_action(stdscr, js_file, axis_state, action_debounce, timeout=0.1):
    """Blocks up to `timeout` seconds for keyboard or joystick input, and
    returns one of "up"/"down"/"left"/"right"/"confirm"/"back"/None.
    `action_debounce` is a dict (persisted by the caller across calls) used
    to suppress bounced repeats of "confirm"/"back"."""
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        action = "confirm"
                    elif number == BTN_BACK:
                        action = "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch == curses.KEY_LEFT:
            return "left"
        if ch == curses.KEY_RIGHT:
            return "right"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


class Player:
    """Thin wrapper around python-vlc for single-track audio playback.
    Runs at a fixed 100% internal volume - actual loudness is controlled
    entirely by the system mixer (see get_system_volume/
    set_system_volume_step) so it's the same volume the hardware hotkeys
    and every other pi-arcade-setup tool control, not a separate
    per-player level that can drift out of sync with them."""

    def __init__(self):
        self.instance = vlc.Instance("--no-video", "--quiet")
        self.mp = self.instance.media_player_new()
        self.mp.audio_set_volume(100)
        # Tracked ourselves rather than solely inferred from
        # mp.get_state(): libVLC's own pause() *toggles*, and get_state()
        # can briefly report "Opening"/"Buffering" (neither Playing nor
        # Paused) right after play()/load(), which made a confirm press
        # that landed in that window silently do the wrong thing. Explicit
        # set_pause(0/1) plus our own intent flag makes play/pause
        # deterministic instead of racing VLC's transitional states.
        self._wants_playing = False

    def load(self, path):
        media = self.instance.media_new(path)
        self.mp.set_media(media)
        self._wants_playing = False

    def play(self):
        self.mp.play()
        self._wants_playing = True

    def pause(self):
        self.mp.set_pause(1)
        self._wants_playing = False

    def toggle_play_pause(self):
        if self._wants_playing:
            self.pause()
        else:
            self.play()

    def stop(self):
        self.mp.stop()
        self._wants_playing = False

    def is_playing(self):
        return self._wants_playing

    def is_ended(self):
        return self.mp.get_state() in (vlc.State.Ended, vlc.State.Error)

    def get_time(self):
        return self.mp.get_time()

    def get_length(self):
        return self.mp.get_length()

    def release(self):
        try:
            self.mp.stop()
            self.mp.release()
            self.instance.release()
        except Exception:
            pass


def draw(win, tracks, sel, now_idx, player, vol, muted, js_connected, t):
    win.erase()
    h, w = win.getmaxyx()

    title_bar = "♪  M U S I C   P L A Y E R  ♪"
    safe_addstr(win, 0, cx(win, title_bar), title_bar, curses.color_pair(COL_HEADER) | curses.A_BOLD)

    card_w = min(w - 4, 66)
    card_x = max(0, (w - card_w) // 2)
    top = 2
    card_h = 8

    safe_addstr(win, top, card_x, "┌" + "─" * (card_w - 2) + "┐", curses.color_pair(COL_ACCENT))
    for row in range(1, card_h):
        safe_addstr(win, top + row, card_x, "│", curses.color_pair(COL_ACCENT))
        safe_addstr(win, top + row, card_x + card_w - 1, "│", curses.color_pair(COL_ACCENT))
    safe_addstr(win, top + card_h, card_x, "└" + "─" * (card_w - 2) + "┘", curses.color_pair(COL_ACCENT))

    inner_w = card_w - 4
    playing = bool(player and player.is_playing())
    if now_idx is not None and 0 <= now_idx < len(tracks):
        tr = tracks[now_idx]
        title_line = marquee(tr["title"], inner_w, t) if playing else tr["title"].center(inner_w)[:inner_w]
        sub = tr["artist"] + ("  •  " + tr["album"] if tr["album"] else "") if tr["artist"] else tr["album"]
        state = "▶ Playing" if playing else "❚❚ Paused"
        elapsed = player.get_time() if player else -1
        total = player.get_length() if player else -1
    else:
        title_line = "Select a track and press Enter/X".center(inner_w)[:inner_w]
        sub = ""
        state = "■ Stopped"
        elapsed, total = -1, -1

    safe_addstr(win, top + 2, card_x + 2, title_line, curses.color_pair(COL_LABEL) | curses.A_BOLD)
    safe_addstr(win, top + 3, card_x + 2, sub.center(inner_w)[:inner_w], curses.A_DIM)

    bar_w = max(4, inner_w - 12)
    if total and total > 0 and elapsed is not None and elapsed >= 0:
        frac = clamp(elapsed / total, 0.0, 1.0)
        filled = int(frac * bar_w)
        bar = "━" * filled + "●" + "─" * max(0, bar_w - filled - 1)
    else:
        bar = "─" * bar_w
    prog_line = f"{fmt_time(elapsed):>5} {bar} {fmt_time(total):<5}"
    safe_addstr(win, top + 5, card_x + 2 + cx_in(inner_w, prog_line), prog_line, curses.color_pair(COL_LABEL))

    ctrl_line = f"◄◄        {state}        ►►"
    ctrl_attr = curses.color_pair(COL_GOOD if playing else COL_HINT) | curses.A_BOLD
    safe_addstr(win, top + 7, card_x + cx_in(inner_w, ctrl_line), ctrl_line, ctrl_attr)

    list_top = top + card_h + 2
    header = "── Library " + "─" * max(0, inner_w - 10)
    safe_addstr(win, list_top, card_x + 2, header[:inner_w], curses.A_DIM)

    list_h = max(1, h - list_top - 4)
    if len(tracks) <= list_h:
        start = 0
    else:
        start = clamp(sel - list_h // 2, 0, max(0, len(tracks) - list_h))
    for row in range(list_h):
        idx = start + row
        y = list_top + 1 + row
        if idx >= len(tracks):
            break
        tr = tracks[idx]
        marker = "▸ " if idx == sel else "  "
        playing_marker = "♪ " if idx == now_idx else "  "
        label = f"{marker}{playing_marker}{tr['title']}"
        if tr["artist"]:
            label += f"  —  {tr['artist']}"
        attr = (curses.color_pair(COL_SEL) | curses.A_BOLD) if idx == sel else curses.color_pair(COL_LABEL)
        safe_addstr(win, y, card_x + 2, label[:inner_w], attr)

    if vol is not None:
        vol_w = 20
        vol_filled = int((vol / 100) * vol_w)
        vol_bar = "▮" * vol_filled + "▯" * (vol_w - vol_filled)
        mute_tag = " (muted)" if muted else ""
        vol_line = f"Vol {vol_bar} {vol:>3}%{mute_tag}"
        safe_addstr(win, h - 3, cx(win, vol_line), vol_line, curses.color_pair(COL_HINT))

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 2, cx(win, js_line), js_line, curses.color_pair(COL_GOOD if js_connected else COL_BAD) | curses.A_DIM)

    footer = "UP/DOWN: browse   LEFT/RIGHT: volume   Enter/A/X: play-pause   ESC/B/Circle: exit"
    safe_addstr(win, h - 1, cx(win, footer), footer, curses.A_DIM)
    win.refresh()


def show_message(stdscr, lines):
    stdscr.nodelay(False)
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    title = "MUSIC PLAYER"
    safe_addstr(stdscr, 1, cx(stdscr, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)
    y = max(3, h // 2 - len(lines) // 2)
    for i, (text, attr) in enumerate(lines):
        safe_addstr(stdscr, y + i, cx(stdscr, text), text, attr)
    hint = "Press any key to exit"
    safe_addstr(stdscr, y + len(lines) + 2, cx(stdscr, hint), hint, curses.A_DIM)
    stdscr.refresh()
    stdscr.getch()


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_MAGENTA, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_WHITE, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)
    curses.init_pair(COL_SEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_ACCENT, curses.COLOR_MAGENTA, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    if not VLC_AVAILABLE:
        show_message(stdscr, [
            ("python-vlc is not installed", curses.color_pair(COL_BAD) | curses.A_BOLD),
            ("Run: pip install python-vlc --break-system-packages", curses.A_DIM),
        ])
        return

    tracks = scan_library(MUSIC_DIR)
    if not tracks:
        show_message(stdscr, [
            (f"No music found in {MUSIC_DIR}", curses.color_pair(COL_BAD) | curses.A_BOLD),
            ("Add MP3/FLAC/OGG/WAV files and reopen this tool.", curses.A_DIM),
        ])
        return

    cfg = load_config()
    sel = clamp(cfg.get("last_index", 0), 0, len(tracks) - 1)
    now_idx = None

    js_file = open_joystick()
    axis_state = {}
    action_debounce = {}
    player = Player()

    t0 = time.monotonic()
    last_vol_poll = 0.0
    vol, muted = get_system_volume()
    try:
        while True:
            t = time.monotonic() - t0

            # Re-read every second or so rather than every frame, so this
            # also picks up changes made by the hardware hotkeys or another
            # tool while this screen is open, without hammering wpctl.
            if t - last_vol_poll > 1.0:
                vol, muted = get_system_volume()
                last_vol_poll = t

            if now_idx is not None and player.is_ended():
                nxt = now_idx + 1
                if nxt < len(tracks):
                    now_idx = nxt
                    sel = now_idx
                    player.load(tracks[now_idx]["path"])
                    player.play()
                else:
                    now_idx = None

            draw(stdscr, tracks, sel, now_idx, player, vol, muted, js_file is not None, t)
            action = poll_action(stdscr, js_file, axis_state, action_debounce)
            if action is None:
                continue

            if action == "back":
                break
            elif action == "up":
                sel = (sel - 1) % len(tracks)
            elif action == "down":
                sel = (sel + 1) % len(tracks)
            elif action in ("left", "right"):
                step = 1 if action == "right" else -1
                set_system_volume_step(step * 5)
                vol, muted = get_system_volume()
                last_vol_poll = t
            elif action == "confirm":
                if sel == now_idx:
                    player.toggle_play_pause()
                else:
                    now_idx = sel
                    player.load(tracks[now_idx]["path"])
                    player.play()
                cfg["last_index"] = sel
                save_config(cfg)
    finally:
        player.release()
        if js_file is not None:
            js_file.close()
        cfg["last_index"] = sel
        save_config(cfg)


def main():
    curses.wrapper(run)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/music-player.py"

    touch "$PI_HOME/RetroPie/retropiemenu/musicplayer.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "musicplayer.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[musicplayer] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[musicplayer] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}musicplayer.rp)\n{indent}    python3 {pi_home}/scripts/music-player.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[musicplayer] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_bt_speaker_setup() {
    if [ "$ENABLE_BT_SPEAKER" != "true" ]; then
        log "ENABLE_BT_SPEAKER=false, skipping"
        return 0
    fi
    # Turns the Pi into an A2DP sink using BlueALSA (bluez-alsa-utils), not
    # PipeWire/WirePlumber's own bluez5 SPA monitor. That was the original
    # design (this OS image already runs PipeWire for everything else), but
    # it turned out unreliable specifically for A2DP on this Pi's onboard
    # Bluetooth chip: media endpoints got registered/unregistered per
    # connection attempt instead of staying up, and profile connections
    # consistently failed as NotAvailable even once a phone was paired -
    # confirmed live via btmon HCI captures across many repeated attempts.
    # BlueALSA registers the Audio Sink profile with bluetoothd once,
    # persistently, at its own startup, and its companion bluealsa-aplay
    # plays the decoded audio into the Pi's normal "default" ALSA device -
    # which still resolves through PipeWire (see phase_audio_output_setup),
    # so it comes out the same pinned aux/HDMI output as everything else.
    # python3-dbus/python3-gi back this project's own pairing agent and the
    # AVRCP now-playing daemon below.
    sudo apt-get install -y bluez-alsa-utils python3-dbus python3-gi \
        || { log_warn "Bluetooth speaker dependency install failed; skipping"; return 0; }

    # BlueZ's "hostname" plugin (loaded by default) overrides main.conf's
    # Name= with the system's pretty hostname, so that - not main.conf - is
    # what actually controls the name phones see when scanning.
    echo "PRETTY_HOSTNAME=$BT_SPEAKER_NAME" | sudo tee /etc/machine-info >/dev/null

    # Idempotent: only inserts once, guarded by a marker comment.
    if ! sudo grep -q "# pi-arcade-setup" /etc/bluetooth/main.conf 2>/dev/null; then
        sudo python3 - /etc/bluetooth/main.conf <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "[General]"
idx = text.find(anchor)
insert_at = idx + len(anchor) if idx != -1 else 0
block = (
    "\n# pi-arcade-setup: speaker, identifies as an Audio/Video Loudspeaker\n"
    "# (Rendering + Audio service bits, per the Bluetooth CoD spec) so it\n"
    "# shows up sensibly in phone BT device lists. Discoverable/pairable are\n"
    "# toggled at runtime by bt-power-on.service (off, at boot) and\n"
    "# bt-nowplaying.py (on, only while the \"Bluetooth Player\" screen is\n"
    "# open) - these timeouts just mean \"stay in whatever state you're put\n"
    "# in\" rather than auto-reverting on their own.\n"
    "Class = 0x240414\n"
    "DiscoverableTimeout = 0\n"
    "PairableTimeout = 0\n"
    "AlwaysPairable = true\n"
)
new_text = text[:insert_at] + block + text[insert_at:]
open(path, "w").write(new_text)
print("[bt-speaker] patched /etc/bluetooth/main.conf")
PYEOF
    fi

    sudo systemctl restart bluetooth
    sleep 1
    sudo bluetoothctl power on >/dev/null 2>&1 || true

    # Persist the pi user's PipeWire session across reboots - bluealsa-aplay
    # plays into its "default" ALSA device, which resolves through this
    # session's PipeWire (for the aux-pinned output, see
    # phase_audio_output_setup), so it needs to always be up, independent of
    # whether a console/graphical session is active.
    sudo loginctl enable-linger "$PI_USER" || log_warn "could not enable linger for $PI_USER"

    local uid
    uid="$(id -u "$PI_USER")"

    # Disable PipeWire's own bluez5 SPA monitor entirely now that BlueALSA
    # owns A2DP - otherwise the two would both try to register the same
    # Bluetooth audio profile with bluetoothd.
    sudo -u "$PI_USER" mkdir -p "$PI_HOME/.config/wireplumber/wireplumber.conf.d"
    sudo -u "$PI_USER" tee "$PI_HOME/.config/wireplumber/wireplumber.conf.d/51-disable-bluez-monitor.conf" >/dev/null <<'CONF'
# pi-arcade-setup: BlueALSA (bluealsa.service) owns A2DP, not PipeWire's own
# bluez5 SPA monitor - disable the latter so they don't both try to
# register the same Bluetooth audio profile with bluetoothd. See
# phase_bt_speaker_setup in install.sh for why.
wireplumber.profiles = {
  main = {
    hardware.bluetooth = disabled
  }
}
CONF
    sudo -u "$PI_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null \
        || log_warn "could not restart pipewire/wireplumber user services; apply on next login"

    mkdir -p "$PI_HOME/scripts"

    tee "$PI_HOME/scripts/bt-pairing-agent.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Headless Bluetooth pairing agent for pi-arcade-setup, run as a systemd
service (bt-agent.service). Auto-accepts every pairing request with no PIN
prompt on either side ("Just Works"/"NoInputNoOutput" capability) - the
same policy `bt-agent` from bluez-tools was supposed to provide, but that
binary turned out to be unreliable on this BlueZ/D-Bus version: it printed
"Agent registered" at startup and then hung - its GLib main loop never
actually pumped, so it never answered a single RequestConfirmation call
(confirmed live: its own journal stayed completely empty across several
real pairing attempts, and it needed SIGKILL on every stop/restart because
it was wedged, not just slow). BlueZ has no fallback for an agent that's
registered-but-unresponsive: it rejects the confirmation in under a
millisecond rather than waiting on a dead process, which looked exactly
like a rejected pairing to every phone that tried.

This replaces it with a small, direct implementation of BlueZ's
org.bluez.Agent1 D-Bus interface (the same approach already used
elsewhere in this project - see bt-controller-pair.py and
bt-nowplaying-daemon.py - rather than depending on a third-party binary).
"""
import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "org.bluez"
AGENT_MANAGER_IFACE = "org.bluez.AgentManager1"
AGENT_IFACE = "org.bluez.Agent1"
AGENT_PATH = "/pi_arcade_setup/pairing_agent"
# Advertised as DisplayYesNo, not NoInputNoOutput, even though this agent
# never actually displays anything or asks a human - confirmed live (via
# btmon HCI capture) that phones requesting MITM-protected "Dedicated
# Bonding" during pairing get auto-rejected by BlueZ itself before the
# agent is ever consulted, specifically because NoInputNoOutput cannot
# satisfy that MITM requirement (bluetoothd won't silently downgrade
# security below what the peer asked for). DisplayYesNo can satisfy it,
# and RequestConfirmation below still auto-accepts unconditionally, so
# pairing stays fully unattended either way.
CAPABILITY = "DisplayYesNo"


class PairingAgent(dbus.service.Object):
    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        print("[bt-pairing-agent] Release()")

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        # Accept every profile/service a paired-or-pairing device asks for -
        # this Pi is a dedicated speaker/controller-pairing kiosk, not a
        # multi-tenant machine that needs a human gatekeeping each profile.
        print(f"[bt-pairing-agent] AuthorizeService({device}, {uuid}) -> accept")
        return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        return "0000"

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_IFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        pass

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        pass

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        # The auto-accept: no comparison, no prompt, matching a
        # NoInputNoOutput/"Just Works" capability on both this and every
        # other pi-arcade-setup Bluetooth tool.
        print(f"[bt-pairing-agent] RequestConfirmation({device}, {passkey}) -> accept")
        return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print(f"[bt-pairing-agent] RequestAuthorization({device}) -> accept")
        return

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self):
        print("[bt-pairing-agent] Cancel()")


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    agent = PairingAgent(bus, AGENT_PATH)

    manager = dbus.Interface(bus.get_object(BUS_NAME, "/org/bluez"), AGENT_MANAGER_IFACE)
    manager.RegisterAgent(AGENT_PATH, CAPABILITY)
    manager.RequestDefaultAgent(AGENT_PATH)

    print(f"[bt-pairing-agent] registered as default agent (capability={CAPABILITY})")
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/bt-pairing-agent.py"

    tee "$PI_HOME/scripts/bt-nowplaying-daemon.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Background daemon for pi-arcade-setup's Bluetooth speaker mode. Polls BlueZ
over D-Bus (no GLib mainloop needed - plain synchronous ObjectManager
polling) for the connected device and its AVRCP MediaPlayer1 metadata,
writes it to STATUS_FILE for the "Bluetooth Player" RetroPie menu tool to
read, and executes playback commands the same tool writes to COMMAND_FILE
(play_pause/next/previous). Also auto-trusts newly paired devices so
reconnects don't need re-pairing.

Runs as a systemd service (bt-nowplaying-daemon.service), independent of
whether the "Bluetooth Player" UI is open - same pattern as the LED strip
daemon.
"""
import json
import os
import time

import dbus

STATUS_FILE = "$PI_HOME/.bt-nowplaying-status.json"
COMMAND_FILE = "$PI_HOME/.bt-nowplaying-command.json"
# Touched by bt-nowplaying.py on start and removed on exit - lets this
# always-on daemon know whether the "Bluetooth Player" screen is currently
# open, so the Pi only actively behaves as a Bluetooth *audio* device
# (proactively connecting A2DP, staying connected) while that screen is
# up, and reverts to a plain Bluetooth host - explicitly disconnecting any
# connected phone - the moment it's closed. This is what keeps game/UI
# audio on the Pi's own output and keeps the single Bluetooth radio's time
# free for a paired game controller the rest of the time, rather than the
# Pi silently remaining an audio sink in the background forever.
ACTIVE_FLAG_FILE = "$PI_HOME/.bt-nowplaying-active"
POLL_INTERVAL = 1.0

BLUEZ_SERVICE = "org.bluez"
DEVICE_IFACE = "org.bluez.Device1"
PLAYER_IFACE = "org.bluez.MediaPlayer1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
AUDIO_SINK_UUID = "0000110b-0000-1000-8000-00805f9b34fb"
RECONNECT_RETRY_S = 5.0
# A2DP is provided by BlueALSA (bluealsa.service + bluealsa-aplay.service),
# which registers the Audio Sink profile with bluetoothd persistently at
# its own startup - not PipeWire's bluez5 SPA monitor, which turned out
# unreliable for this specific onboard-Bluetooth-chip + A2DP combination
# (endpoints registered/unregistered per-connection instead of staying up,
# profile connections consistently failing as NotAvailable even once
# paired - confirmed live via btmon). Retried on a short interval mainly
# so a phone that doesn't proactively reopen A2DP on its own gets pulled
# back in automatically rather than sitting paired-but-silent.
_last_connect_attempt = {}
_last_connected_path = None
# Tracks whichever device path enforce_single_connection() last decided to
# keep, so a newly-appearing second connection can be told apart from the
# one that was already there (see enforce_single_connection below).
_last_active_path = None
# Tracks whichever device path was last actually seen Connected, updated in
# main()'s poll loop. Used to scope reconnect_paired_devices() to only the
# single device that was in use most recently - see that function for why.


def get_managed_objects(bus):
    try:
        manager = dbus.Interface(
            bus.get_object(BLUEZ_SERVICE, "/"), "org.freedesktop.DBus.ObjectManager"
        )
        return manager.GetManagedObjects()
    except Exception:
        return {}


def find_connected_device_and_player(objects):
    device_path, device_props = None, None
    for path, ifaces in objects.items():
        dev = ifaces.get(DEVICE_IFACE)
        if dev and bool(dev.get("Connected")):
            device_path, device_props = path, dev
            break

    if device_path is None:
        return None, None, None, None

    player_path, player_props = None, None
    for path, ifaces in objects.items():
        if path.startswith(device_path) and PLAYER_IFACE in ifaces:
            player_path, player_props = path, ifaces[PLAYER_IFACE]
            break

    return device_path, device_props, player_path, player_props


def auto_trust(bus, objects):
    for path, ifaces in objects.items():
        dev = ifaces.get(DEVICE_IFACE)
        if dev and bool(dev.get("Paired")) and not bool(dev.get("Trusted")):
            try:
                props = dbus.Interface(bus.get_object(BLUEZ_SERVICE, path), PROPS_IFACE)
                props.Set(DEVICE_IFACE, "Trusted", True)
                print(f"[bt-nowplaying] auto-trusted {path}")
            except Exception as e:
                print(f"[bt-nowplaying] failed to trust {path}: {e}")


def reconnect_paired_devices(bus, objects):
    """While the Bluetooth Player screen is open: if the single device that
    was most recently actually in use (_last_active_path) has dropped its
    A2DP link without a new device taking over, (re)request the Audio Sink
    profile specifically for THAT device only - not a generic
    Device1.Connect(), which also tries the complementary a2dp-source
    profile and hard-fails the whole attempt with
    br-connection-profile-unavailable if that role isn't registered.
    Throttled per-device rather than hammered every poll.

    Deliberately scoped to one device, not "every paired device": this
    only exists to pull the phone/laptop you were just listening from back
    in if it drops out (walked out of range, brief link loss) without you
    doing anything, not to keep hunting down every other device this Pi
    has ever been paired with. Reconnecting indiscriminately meant an old,
    already-disconnected device (e.g. a laptop the user just intentionally
    disconnected from) could get raced back in by this same loop right
    while a completely different device (a phone) was being connected from
    its own side - competing for the single A2DP link the onboard radio
    can actually hold, and either getting shown instead of the new device
    or interfering with its connection outright. Also skipped entirely if
    something is already connected, for the same reason.

    If nothing has been active yet this run (_last_active_path is still
    None - e.g. right after the daemon or the Pi itself starts), this is
    deliberately a no-op: the very first connection of a session should
    always come from the device's own side, not from this Pi guessing
    which of its paired devices to chase."""
    if any(bool(ifaces.get(DEVICE_IFACE, {}).get("Connected")) for ifaces in objects.values()):
        return
    if _last_active_path is None:
        return
    ifaces = objects.get(_last_active_path)
    dev = ifaces.get(DEVICE_IFACE) if ifaces else None
    if not dev or not bool(dev.get("Paired")) or bool(dev.get("Connected")):
        return
    now = time.time()
    if now - _last_connect_attempt.get(_last_active_path, 0.0) < RECONNECT_RETRY_S:
        return
    _last_connect_attempt[_last_active_path] = now
    try:
        device = dbus.Interface(bus.get_object(BLUEZ_SERVICE, _last_active_path), DEVICE_IFACE)
        device.ConnectProfile(AUDIO_SINK_UUID)
        print(f"[bt-nowplaying] reconnected {_last_active_path}")
    except Exception as e:
        print(f"[bt-nowplaying] reconnect attempt for {_last_active_path} failed: {e}")


def enforce_single_connection(bus, objects):
    """Only one phone/laptop should be treated as the active audio source
    at a time. If more than one device ends up Connected simultaneously -
    e.g. an old device's own reconnect timer fired right as a new device
    was being paired/connected from its own side - keep only whichever
    one is new (not the device we already knew about from the previous
    poll) and disconnect the rest, so a stale device can't linger and
    get shown or fought over instead of the one actually in use."""
    global _last_connected_path
    connected = [
        path for path, ifaces in objects.items()
        if bool(ifaces.get(DEVICE_IFACE, {}).get("Connected"))
    ]
    if len(connected) <= 1:
        _last_connected_path = connected[0] if connected else None
        return

    keep = next((p for p in connected if p != _last_connected_path), connected[0])
    for path in connected:
        if path == keep:
            continue
        try:
            device = dbus.Interface(bus.get_object(BLUEZ_SERVICE, path), DEVICE_IFACE)
            device.Disconnect()
            print(f"[bt-nowplaying] disconnected stale device {path} (new device took over)")
        except Exception as e:
            print(f"[bt-nowplaying] failed to disconnect stale device {path}: {e}")
    _last_connected_path = keep


def disconnect_all(bus, objects):
    """Explicitly drops any connected phone - used when the Bluetooth
    Player screen closes, so the Pi stops being a Bluetooth audio device
    the instant the user leaves that screen rather than leaving a phone
    connected (and holding radio time a paired game controller needs) in
    the background indefinitely."""
    for path, ifaces in objects.items():
        dev = ifaces.get(DEVICE_IFACE)
        if dev and bool(dev.get("Connected")):
            try:
                device = dbus.Interface(bus.get_object(BLUEZ_SERVICE, path), DEVICE_IFACE)
                device.Disconnect()
                print(f"[bt-nowplaying] disconnected {path} (Bluetooth Player closed)")
            except Exception as e:
                print(f"[bt-nowplaying] disconnect of {path} failed: {e}")


def jstr(v, default=""):
    try:
        return str(v)
    except Exception:
        return default


def write_status(device_props, player_path, player_props):
    status = {"connected": False, "device_name": "", "device_address": ""}
    if device_props is not None:
        status["connected"] = True
        status["device_name"] = jstr(device_props.get("Name", device_props.get("Alias", "")))
        status["device_address"] = jstr(device_props.get("Address", ""))

    status["has_player"] = player_path is not None
    if player_props is not None:
        track = player_props.get("Track", {})
        status["title"] = jstr(track.get("Title", ""))
        status["artist"] = jstr(track.get("Artist", ""))
        status["album"] = jstr(track.get("Album", ""))
        duration = track.get("Duration")
        status["duration_ms"] = int(duration) if duration is not None else -1
        status["position_ms"] = int(player_props.get("Position", -1))
        status["status"] = jstr(player_props.get("Status", "stopped")).lower()
    else:
        status["title"] = ""
        status["artist"] = ""
        status["album"] = ""
        status["duration_ms"] = -1
        status["position_ms"] = -1
        status["status"] = "stopped"

    status["updated"] = time.time()
    try:
        tmp = STATUS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(status, f)
        os.replace(tmp, STATUS_FILE)
    except Exception:
        pass


def read_command():
    if not os.path.exists(COMMAND_FILE):
        return None
    try:
        with open(COMMAND_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def clear_command():
    try:
        os.remove(COMMAND_FILE)
    except Exception:
        pass


def run_command(bus, player_path, cmd):
    if not player_path or not cmd:
        return
    action = cmd.get("cmd")
    if action not in ("play_pause", "next", "previous"):
        return
    try:
        player = dbus.Interface(bus.get_object(BLUEZ_SERVICE, player_path), PLAYER_IFACE)
        if action == "play_pause":
            props = dbus.Interface(bus.get_object(BLUEZ_SERVICE, player_path), PROPS_IFACE)
            status = jstr(props.Get(PLAYER_IFACE, "Status")).lower()
            if status == "playing":
                player.Pause()
            else:
                player.Play()
        elif action == "next":
            player.Next()
        elif action == "previous":
            player.Previous()
    except Exception as e:
        print(f"[bt-nowplaying] command '{action}' failed: {e}")


def main():
    global _last_active_path
    bus = dbus.SystemBus()
    last_seq = None
    was_active = False
    while True:
        objects = get_managed_objects(bus)
        is_active = os.path.exists(ACTIVE_FLAG_FILE)

        if is_active:
            auto_trust(bus, objects)
            reconnect_paired_devices(bus, objects)
            enforce_single_connection(bus, objects)
        elif was_active:
            # Bluetooth Player just closed - drop any connected phone so
            # the Pi goes back to being a plain host device immediately,
            # not whenever that phone eventually times out on its own.
            disconnect_all(bus, objects)
            objects = get_managed_objects(bus)
            _last_active_path = None
        was_active = is_active

        device_path, device_props, player_path, player_props = find_connected_device_and_player(objects)
        if device_path is not None:
            _last_active_path = device_path
        write_status(device_props, player_path, player_props)

        cmd = read_command()
        if cmd is not None and cmd.get("seq") != last_seq:
            last_seq = cmd.get("seq")
            run_command(bus, player_path, cmd)
            clear_command()

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/bt-nowplaying-daemon.py"

    # BlueALSA defaults to advertising both a2dp-sink and a2dp-source; this
    # Pi only ever needs to be a sink, so trim it to just that.
    sudo mkdir -p /etc/systemd/system/bluealsa.service.d
    sudo tee /etc/systemd/system/bluealsa.service.d/override.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/bluealsa -S --keep-alive=5 -p a2dp-sink
EOF

    # bluealsa-aplay opens a fresh connection to the ALSA PCM device for
    # every new Bluetooth audio stream (its own documented behavior, not a
    # bug) - which happens not just once at connection time but again at
    # every track change on some sources (confirmed live: a MacBook's A2DP
    # session does this), each time briefly re-negotiating/re-filling
    # buffers. The default 500ms PCM buffer is too tight to absorb that
    # without an audible chop; doubling it to 1s gives enough headroom to
    # ride through a stream restart smoothly, at the cost of a bit more
    # latency - an easy trade for background music playback, not a
    # real-time game. --single-audio is redundant with (but a cheap second
    # line of defense alongside) bt-nowplaying-daemon.py's own single-
    # active-connection enforcement, for the brief window between an old
    # device's stale reconnect and the daemon's next poll dropping it.
    sudo mkdir -p /etc/systemd/system/bluealsa-aplay.service.d
    sudo tee /etc/systemd/system/bluealsa-aplay.service.d/override.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/bluealsa-aplay -S --single-audio --pcm-buffer-time=1000000 --pcm-period-time=100000
EOF

    # bt-agent/bt-nowplaying-daemon After/Wants bt-power-on.service (not
    # just bluetooth.service) so bt-power-on always starts first - but this
    # alone isn't enough to stop bt-power-on's own "org.bluez.Error.Busy"
    # failures (confirmed live via journalctl), because bluetoothd is also
    # concurrently fielding endpoint-registration D-Bus calls from other
    # independent startup paths at the exact same moment - bluealsa.service
    # (registers the Audio Sink profile) and the pi user's own PipeWire/
    # WirePlumber session (started via loginctl linger, entirely unordered
    # relative to any root-level systemd unit) both do this, and neither is
    # something bt-power-on can simply be ordered after without adding a
    # much more fragile web of cross-user-session dependencies. The
    # ExecStart below retries each bluetoothctl call instead of running it
    # once, which resolves the transient "Busy" without needing to track
    # down every possible concurrent initializer up front.
    sudo tee /etc/systemd/system/bt-agent.service >/dev/null <<EOF
[Unit]
Description=Headless Bluetooth pairing agent (auto-accept, DisplayYesNo)
After=bluetooth.service dbus.service bt-power-on.service
Wants=bt-power-on.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u $PI_HOME/scripts/bt-pairing-agent.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Clean up the old always-discoverable service and third-party bt-agent
    # binary from earlier versions of this script, if present (upgrade
    # path) - superseded by bt-power-on.service and bt-pairing-agent.py
    # respectively (bluez-tools' own bt-agent turned out to hang and never
    # actually answer a pairing request - confirmed live via its own empty
    # journal across several real attempts).
    if [ -f /etc/systemd/system/bt-discoverable.service ]; then
        sudo systemctl disable --now bt-discoverable.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/bt-discoverable.service
    fi
    sudo pkill -9 -f "bt-agent -c" 2>/dev/null || true

    # Powers the adapter on at boot only - deliberately does NOT enable
    # discoverable/pairable here. Being discoverable to new devices is
    # scoped to the "Bluetooth Player" app's own lifetime (it turns
    # discoverable/pairable on when opened and off again when closed, see
    # bt-nowplaying.py) so the Pi doesn't sit there permanently advertising
    # itself as $BT_SPEAKER_NAME to every phone in range. Already-paired/
    # trusted devices can still reconnect at any time - only *first-time*
    # pairing requires the app to be open.
    sudo tee /etc/systemd/system/bt-power-on.service >/dev/null <<EOF
[Unit]
Description=Power on the Bluetooth adapter at boot (not discoverable/pairable by default)
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'for c in "power on" "discoverable off" "pairable off"; do for i in 1 2 3 4 5; do bluetoothctl \$c && break; sleep 1; done; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/bt-nowplaying-daemon.service >/dev/null <<EOF
[Unit]
Description=Bluetooth AVRCP now-playing status/control daemon
After=bluetooth.service dbus.service bt-power-on.service
Wants=bt-power-on.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u $PI_HOME/scripts/bt-nowplaying-daemon.py
Restart=always
RestartSec=2
User=root
StandardOutput=append:/var/log/bt-nowplaying-daemon.log
StandardError=append:/var/log/bt-nowplaying-daemon.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now bluealsa.service bluealsa-aplay.service
    sudo systemctl enable --now bt-agent.service bt-power-on.service bt-nowplaying-daemon.service
    return 0
}

phase_bt_pair_tool() {
    if [ "$ENABLE_BT_SPEAKER" != "true" ]; then
        log "ENABLE_BT_SPEAKER=false, skipping"
        return 0
    fi
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/bt-controller-pair.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Seamless Bluetooth device pairing wizard for pi-arcade-setup - mainly for
wireless controllers, but works for any discoverable device. Run from the
RetroPie menu ("Bluetooth") or directly:
    python3 bt-controller-pair.py
Drives BlueZ directly over D-Bus (no bluetoothctl text-parsing): scans for
nearby devices and lists them live, and pairs/trusts/connects the selected
one with a single button press. Pairing confirmation is handled
automatically in the background by pi-arcade-setup's own bt-agent service
(NoInputNoOutput/"Just Works"), so no PIN entry is needed here.

Fully navigable by controller as well as keyboard: left stick (or D-pad) to
move, X/Cross to pair the selected device, Circle/B to exit - same button
roles as the rest of the RetroPie menu.
"""
import curses
import select
import struct
import sys
import time

import dbus

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

BLUEZ_SERVICE = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD, COL_SEL = 1, 2, 3, 4, 5, 6


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def find_adapter_path(bus):
    manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE, "/"), "org.freedesktop.DBus.ObjectManager")
    for path, ifaces in manager.GetManagedObjects().items():
        if ADAPTER_IFACE in ifaces:
            return path
    return None


def list_devices(bus, adapter_path):
    manager = dbus.Interface(bus.get_object(BLUEZ_SERVICE, "/"), "org.freedesktop.DBus.ObjectManager")
    devices = []
    for path, ifaces in manager.GetManagedObjects().items():
        dev = ifaces.get(DEVICE_IFACE)
        if dev is None or not path.startswith(adapter_path + "/"):
            continue
        name = str(dev.get("Name", dev.get("Alias", "")))
        addr = str(dev.get("Address", ""))
        devices.append({
            "path": path,
            "name": name or "(unnamed device)",
            "address": addr,
            "paired": bool(dev.get("Paired")),
            "connected": bool(dev.get("Connected")),
            "rssi": int(dev.get("RSSI", -999)),
        })
    # connected/paired first, then by signal strength
    devices.sort(key=lambda d: (not d["connected"], not d["paired"], -d["rssi"]))
    return devices


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


CONFIRM_DEBOUNCE_S = 0.25
# Guards confirm/back specifically (not directional movement) against
# switch/contact bounce on cheap arcade buttons and joystick encoders, which
# can report two or more rapid press events for what is physically a single
# tap - without this a bounced confirm press could fire pair_device() twice
# in quick succession for the same target.


def poll_action(stdscr, js_file, axis_state, action_debounce, timeout=0.15):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        action = "confirm"
                    elif number == BTN_BACK:
                        action = "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


def draw(win, devices, sel, js_connected, status_line, status_attr, scanning):
    win.erase()
    h, w = win.getmaxyx()
    title = " BLUETOOTH PAIRING "
    safe_addstr(win, 1, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)
    sub = "Scanning for nearby devices..." if scanning else "Scan paused"
    safe_addstr(win, 2, cx(win, sub), sub, curses.A_DIM)

    top = 4
    if not devices:
        empty = "No devices found yet - put your controller in pairing mode"
        safe_addstr(win, top + 1, cx(win, empty), empty, curses.A_DIM)
    else:
        list_h = max(1, h - top - 6)
        start = 0
        if len(devices) > list_h:
            start = max(0, min(sel - list_h // 2, len(devices) - list_h))
        for row in range(list_h):
            idx = start + row
            if idx >= len(devices):
                break
            d = devices[idx]
            marker = "▸ " if idx == sel else "  "
            tags = []
            if d["connected"]:
                tags.append("connected")
            elif d["paired"]:
                tags.append("paired")
            tag_str = f" [{', '.join(tags)}]" if tags else ""
            label = f"{marker}{d['name']} ({d['address']}){tag_str}"
            attr = (curses.color_pair(COL_SEL) | curses.A_BOLD) if idx == sel else curses.color_pair(COL_LABEL)
            if d["connected"]:
                attr = curses.color_pair(COL_GOOD) | (curses.A_BOLD if idx == sel else 0)
            safe_addstr(win, top + row, cx(win, label) if len(label) < w - 4 else 2, label, attr)

    if status_line:
        safe_addstr(win, h - 5, cx(win, status_line), status_line, status_attr | curses.A_BOLD)

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 3, cx(win, js_line), js_line, curses.color_pair(COL_GOOD if js_connected else COL_BAD) | curses.A_DIM)

    footer = "UP/DOWN: select   Enter/A/X: pair & connect   ESC/B/Circle: exit"
    safe_addstr(win, h - 2, cx(win, footer), footer, curses.color_pair(COL_HINT))
    win.refresh()


def pair_device(bus, path):
    device = bus.get_object(BLUEZ_SERVICE, path)
    device_iface = dbus.Interface(device, DEVICE_IFACE)
    props = dbus.Interface(device, PROPS_IFACE)
    try:
        if not bool(props.Get(DEVICE_IFACE, "Paired")):
            device_iface.Pair(timeout=15000)
        props.Set(DEVICE_IFACE, "Trusted", True)
        device_iface.Connect(timeout=15000)
        return True, "Paired and connected!"
    except dbus.exceptions.DBusException as e:
        msg = str(e)
        if "AlreadyExists" in msg or "Already Exists" in msg:
            try:
                device_iface.Connect(timeout=15000)
                return True, "Connected!"
            except Exception as e2:
                return False, f"Connect failed: {e2}"
        return False, f"Pairing failed: {msg.split(':')[-1].strip()}"
    except Exception as e:
        return False, f"Pairing failed: {e}"


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)
    curses.init_pair(COL_SEL, curses.COLOR_GREEN, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    axis_state = {}
    action_debounce = {}

    bus = dbus.SystemBus()
    adapter_path = find_adapter_path(bus)
    scanning = False
    status_line, status_attr = "", 0

    if adapter_path is None:
        safe_addstr(stdscr, 2, 2, "No Bluetooth adapter found.", curses.color_pair(COL_BAD))
        stdscr.refresh()
        stdscr.nodelay(False)
        stdscr.getch()
        if js_file:
            js_file.close()
        return

    adapter_props = dbus.Interface(bus.get_object(BLUEZ_SERVICE, adapter_path), PROPS_IFACE)
    adapter_iface = dbus.Interface(bus.get_object(BLUEZ_SERVICE, adapter_path), ADAPTER_IFACE)
    try:
        if not bool(adapter_props.Get(ADAPTER_IFACE, "Powered")):
            adapter_props.Set(ADAPTER_IFACE, "Powered", True)
        adapter_iface.StartDiscovery()
        scanning = True
    except Exception as e:
        status_line, status_attr = f"Could not start scan: {e}", curses.color_pair(COL_BAD)

    sel = 0
    devices = []
    t0 = time.monotonic()
    last_scan_poll = 0.0

    try:
        while True:
            t = time.monotonic() - t0
            if t - last_scan_poll > 1.0:
                devices = list_devices(bus, adapter_path)
                sel = max(0, min(sel, len(devices) - 1)) if devices else 0
                last_scan_poll = t

            draw(stdscr, devices, sel, js_file is not None, status_line, status_attr, scanning)
            action = poll_action(stdscr, js_file, axis_state, action_debounce)
            if action is None:
                continue

            if action == "back":
                break
            elif action == "up" and devices:
                sel = (sel - 1) % len(devices)
            elif action == "down" and devices:
                sel = (sel + 1) % len(devices)
            elif action == "confirm" and devices:
                target = devices[sel]
                status_line, status_attr = f"Pairing with {target['name']}...", curses.color_pair(COL_HINT)
                draw(stdscr, devices, sel, js_file is not None, status_line, status_attr, scanning)
                ok, msg = pair_device(bus, target["path"])
                status_line = msg
                status_attr = curses.color_pair(COL_GOOD) if ok else curses.color_pair(COL_BAD)
                devices = list_devices(bus, adapter_path)
    finally:
        try:
            adapter_iface.StopDiscovery()
        except Exception:
            pass
        if js_file is not None:
            js_file.close()


def main():
    curses.wrapper(run)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/bt-controller-pair.py"

    touch "$PI_HOME/RetroPie/retropiemenu/btpair.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "btpair.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[btpair] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[btpair] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}btpair.rp)\n{indent}    sudo python3 {pi_home}/scripts/bt-controller-pair.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[btpair] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_bt_player_tool() {
    if [ "$ENABLE_BT_SPEAKER" != "true" ]; then
        log "ENABLE_BT_SPEAKER=false, skipping"
        return 0
    fi
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/bt-nowplaying.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Car-infotainment-style "now playing" screen for pi-arcade-setup's
Bluetooth speaker mode. Run from the RetroPie menu ("Bluetooth Player") or
directly:
    python3 bt-nowplaying.py
Shows the track currently streaming from a connected phone via AVRCP
metadata, and can send play/pause/next/previous back to the phone - the
audio itself is handled entirely by the always-on background daemon and
PipeWire, so this tool is only a display+remote. Also adjusts the Pi's
own output volume.

The Pi behaves as a Bluetooth *audio* device - discoverable/pairable to
new phones, and actively holding/reconnecting a paired phone's A2DP link -
only while this screen is open. Closing it disconnects any connected
phone and turns discoverable/pairable back off, so game/UI audio stays on
the Pi's own output the rest of the time and a paired Bluetooth game
controller isn't sharing the single Bluetooth radio with an idle audio
link. None of this touches controller pairing/input at all - that's a
separate Bluetooth profile (HID, handled by the kernel) from the A2DP
audio profile this screen manages.

Fully navigable by controller as well as keyboard: left stick (or D-pad) to
skip tracks or adjust volume, X/Cross to confirm, Circle/B to exit - same
button roles as the rest of the RetroPie menu.
"""
import curses
import json
import os
import select
import struct
import subprocess
import sys
import time

PI_HOME = "$PI_HOME"
STATUS_FILE = "$PI_HOME/.bt-nowplaying-status.json"
COMMAND_FILE = "$PI_HOME/.bt-nowplaying-command.json"
# Tells the always-on background daemon (bt-nowplaying-daemon.py) that this
# screen is open, so it only actively behaves as a Bluetooth audio device -
# proactively connecting/holding a phone's A2DP link - while it's up. See
# ACTIVE_FLAG_FILE in that daemon's source for the full reasoning.
ACTIVE_FLAG_FILE = "$PI_HOME/.bt-nowplaying-active"
SPEAKER_NAME = "$BT_SPEAKER_NAME"

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD, COL_ACCENT = 1, 2, 3, 4, 5, 6

_cmd_seq = 0


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def cx_in(width, text):
    return max(0, (width - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def read_status():
    default = {
        "connected": False, "device_name": "", "has_player": False,
        "title": "", "artist": "", "album": "", "status": "stopped",
        "position_ms": -1, "duration_ms": -1,
    }
    if os.path.exists(STATUS_FILE):
        try:
            with open(STATUS_FILE) as f:
                default.update(json.load(f))
        except Exception:
            pass
    return default


def send_command(cmd):
    global _cmd_seq
    _cmd_seq += 1
    try:
        with open(COMMAND_FILE, "w") as f:
            json.dump({"cmd": cmd, "seq": _cmd_seq}, f)
    except Exception:
        pass


def _wpctl_env():
    """wpctl talks to the calling user's own PipeWire session over
    $XDG_RUNTIME_DIR - but this tool actually runs as root when launched
    from the RetroPie menu (retropiemenu.sh's dispatch inherits that from
    the custom system's `sudo openvt` wrapper), which has no PipeWire
    session of its own. Point it at the Pi user's session (found via who
    owns their home directory, not a hardcoded uid) instead of whatever -
    if anything - root's own XDG_RUNTIME_DIR resolves to."""
    env = dict(os.environ)
    try:
        env["XDG_RUNTIME_DIR"] = f"/run/user/{os.stat(PI_HOME).st_uid}"
    except Exception:
        pass
    return env


def get_volume():
    try:
        out = subprocess.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
                              capture_output=True, text=True, timeout=2, env=_wpctl_env()).stdout
        # format: "Volume: 0.40" or "Volume: 0.40 [MUTED]"
        parts = out.strip().split()
        if len(parts) >= 2:
            vol = int(round(float(parts[1]) * 100))
            muted = "MUTED" in out
            return clamp(vol, 0, 100), muted
    except Exception:
        pass
    return None, False


def set_volume_step(step):
    try:
        sign = "+" if step > 0 else "-"
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{abs(step)}%{sign}"],
                        capture_output=True, timeout=2, env=_wpctl_env())
    except Exception:
        pass


def fmt_time(ms):
    if ms is None or ms < 0:
        return "--:--"
    s = int(ms / 1000)
    return f"{s // 60:02d}:{s % 60:02d}"


def marquee(text, width, t, speed=3.0):
    if width <= 0:
        return ""
    if len(text) <= width:
        return text.center(width)
    pad = text + "     " + text
    offset = int(t * speed) % (len(text) + 5)
    return pad[offset: offset + width]


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


CONFIRM_DEBOUNCE_S = 0.25
# Guards "confirm"/"back" specifically (not directional movement) against
# switch/contact bounce on cheap arcade buttons and joystick encoders, which
# can report two or more rapid press events for what is physically a single
# tap - without this a bounced confirm press could fire play_pause twice in
# quick succession and look like the button "did nothing".


def poll_action(stdscr, js_file, axis_state, action_debounce, timeout=0.2):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        action = "confirm"
                    elif number == BTN_BACK:
                        action = "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch == curses.KEY_LEFT:
            return "left"
        if ch == curses.KEY_RIGHT:
            return "right"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


def set_discoverable(enabled):
    """Toggles whether the Pi shows up as a connectable Bluetooth device to
    *new* phones. Deliberately scoped to this app's lifetime rather than
    left on permanently (see bt-power-on.service): the Pi shouldn't sit
    there always advertising itself to every phone in range. Devices that
    are already paired/trusted can still reconnect at any time regardless
    of this setting - it only gates first-time pairing."""
    state = "on" if enabled else "off"
    try:
        subprocess.run(["bluetoothctl", "discoverable", state], capture_output=True, timeout=3)
        subprocess.run(["bluetoothctl", "pairable", state], capture_output=True, timeout=3)
    except Exception:
        pass


def draw(win, status, vol, muted, js_connected, t):
    win.erase()
    h, w = win.getmaxyx()

    title_bar = "🔊  Bluetooth Player  🔊"
    safe_addstr(win, 0, cx(win, title_bar), title_bar, curses.color_pair(COL_HEADER) | curses.A_BOLD)

    card_w = min(w - 4, 66)
    card_x = max(0, (w - card_w) // 2)
    top = 2
    card_h = 8

    safe_addstr(win, top, card_x, "┌" + "─" * (card_w - 2) + "┐", curses.color_pair(COL_ACCENT))
    for row in range(1, card_h):
        safe_addstr(win, top + row, card_x, "│", curses.color_pair(COL_ACCENT))
        safe_addstr(win, top + row, card_x + card_w - 1, "│", curses.color_pair(COL_ACCENT))
    safe_addstr(win, top + card_h, card_x, "└" + "─" * (card_w - 2) + "┘", curses.color_pair(COL_ACCENT))

    inner_w = card_w - 4
    connected = status.get("connected", False)
    playing = status.get("status") == "playing"

    if not connected:
        conn_line = "No device connected".center(inner_w)[:inner_w]
        safe_addstr(win, top + 2, card_x + 2, conn_line, curses.color_pair(COL_BAD) | curses.A_BOLD)
        hint = f'Pair a device to "{SPEAKER_NAME}" to stream music here'
        safe_addstr(win, top + 4, card_x + 2, hint.center(inner_w)[:inner_w], curses.A_DIM)
    else:
        dev_line = f"Connected: {status.get('device_name') or status.get('device_address', '?')}"
        safe_addstr(win, top + 1, card_x + 2, dev_line.center(inner_w)[:inner_w], curses.color_pair(COL_GOOD))

        if status.get("has_player") and (status.get("title") or status.get("artist")):
            title = status.get("title") or "(unknown track)"
            title_line = marquee(title, inner_w, t) if playing else title.center(inner_w)[:inner_w]
            sub = status.get("artist", "") + ("  •  " + status["album"] if status.get("album") else "")
            state = "▶ Playing" if playing else "❚❚ Paused"
            elapsed = status.get("position_ms", -1)
            total = status.get("duration_ms", -1)
        else:
            title_line = "No track metadata yet".center(inner_w)[:inner_w]
            sub = "(play something on your device)"
            state = "■ Idle"
            elapsed, total = -1, -1

        safe_addstr(win, top + 3, card_x + 2, title_line, curses.color_pair(COL_LABEL) | curses.A_BOLD)
        safe_addstr(win, top + 4, card_x + 2, sub.center(inner_w)[:inner_w], curses.A_DIM)

        bar_w = max(4, inner_w - 12)
        if total and total > 0 and elapsed is not None and elapsed >= 0:
            frac = clamp(elapsed / total, 0.0, 1.0)
            filled = int(frac * bar_w)
            bar = "━" * filled + "●" + "─" * max(0, bar_w - filled - 1)
        else:
            bar = "─" * bar_w
        prog_line = f"{fmt_time(elapsed):>5} {bar} {fmt_time(total):<5}"
        safe_addstr(win, top + 5, card_x + 2 + cx_in(inner_w, prog_line), prog_line, curses.color_pair(COL_LABEL))

        ctrl_line = f"◄◄        {state}        ►►"
        ctrl_attr = curses.color_pair(COL_GOOD if playing else COL_HINT) | curses.A_BOLD
        safe_addstr(win, top + 7, card_x + cx_in(inner_w, ctrl_line), ctrl_line, ctrl_attr)

    if vol is not None:
        vol_w = 20
        vol_filled = int((vol / 100) * vol_w)
        vol_bar = "▮" * vol_filled + "▯" * (vol_w - vol_filled)
        mute_tag = " (muted)" if muted else ""
        vol_line = f"Vol {vol_bar} {vol:>3}%{mute_tag}"
        safe_addstr(win, h - 4, cx(win, vol_line), vol_line, curses.color_pair(COL_HINT))

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 3, cx(win, js_line), js_line, curses.color_pair(COL_GOOD if js_connected else COL_BAD) | curses.A_DIM)

    footer1 = "LEFT/RIGHT: prev/next track   UP/DOWN: volume"
    footer2 = "Enter/A/X: play-pause   ESC/B/Circle: exit (music keeps playing)"
    safe_addstr(win, h - 2, cx(win, footer1), footer1, curses.A_DIM)
    safe_addstr(win, h - 1, cx(win, footer2), footer2, curses.A_DIM)
    win.refresh()


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_WHITE, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)
    curses.init_pair(COL_ACCENT, curses.COLOR_CYAN, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    axis_state = {}
    action_debounce = {}

    t0 = time.monotonic()
    last_poll = 0.0
    status = read_status()
    vol, muted = get_volume()

    # Only advertise the Pi to new phones while this screen is open (see
    # set_discoverable's docstring) - always turned back off in the
    # `finally` block below, however this loop exits. Same idea for the
    # active-flag file: it tells the background daemon to actively hold/
    # reconnect a phone's audio link only while this screen is up.
    set_discoverable(True)
    try:
        with open(ACTIVE_FLAG_FILE, "w") as f:
            f.write("1")
    except Exception:
        pass

    try:
        while True:
            t = time.monotonic() - t0
            if t - last_poll > 1.0:
                status = read_status()
                vol, muted = get_volume()
                last_poll = t

            draw(stdscr, status, vol, muted, js_file is not None, t)
            action = poll_action(stdscr, js_file, axis_state, action_debounce)
            if action is None:
                continue

            if action == "back":
                break
            elif action == "confirm":
                send_command("play_pause")
            elif action == "left":
                send_command("previous")
            elif action == "right":
                send_command("next")
            elif action == "up":
                set_volume_step(5)
                vol, muted = get_volume()
            elif action == "down":
                set_volume_step(-5)
                vol, muted = get_volume()
    finally:
        set_discoverable(False)
        try:
            os.remove(ACTIVE_FLAG_FILE)
        except Exception:
            pass
        if js_file is not None:
            js_file.close()


def main():
    curses.wrapper(run)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/bt-nowplaying.py"

    touch "$PI_HOME/RetroPie/retropiemenu/btaudio.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "btaudio.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[btaudio] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[btaudio] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}btaudio.rp)\n{indent}    python3 {pi_home}/scripts/bt-nowplaying.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[btaudio] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_audio_settings_tool() {
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/audio-settings.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Audio output + mixer settings for pi-arcade-setup. Run from the RetroPie
menu ("Audio settings") or directly:
    python3 audio-settings.py
Lets you switch the default PipeWire/WirePlumber output between the aux
(3.5mm) jack and any HDMI output, and adjust master volume/mute - a
controller-navigable front end for `wpctl`.

Fully navigable by controller as well as keyboard: left stick (or D-pad) to
move/adjust, X/Cross to confirm, Circle/B to exit - same button roles as
the rest of the RetroPie menu.
"""
import curses
import os
import re
import select
import struct
import subprocess
import sys
import time

PI_HOME = "$PI_HOME"

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD, COL_SEL = 1, 2, 3, 4, 5, 6

ROWS = ["output", "volume", "mute"]
ROW_LABELS = {"output": "Output", "volume": "Volume", "mute": "Mute"}


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def _wpctl_env():
    """wpctl talks to the calling user's own PipeWire session over
    $XDG_RUNTIME_DIR - but this tool actually runs as root when launched
    from the RetroPie menu (retropiemenu.sh's dispatch inherits that from
    the custom system's `sudo openvt` wrapper), which has no PipeWire
    session of its own. Point it at the Pi user's session (found via who
    owns their home directory, not a hardcoded uid) instead of whatever -
    if anything - root's own XDG_RUNTIME_DIR resolves to."""
    env = dict(os.environ)
    try:
        env["XDG_RUNTIME_DIR"] = f"/run/user/{os.stat(PI_HOME).st_uid}"
    except Exception:
        pass
    return env


def friendly_name(info):
    if "mailbox" in info or "bcm2835 Headphones" in info:
        return "Aux / Headphone jack"
    m = re.search(r'alsa\.card_name\s*=\s*"([^"]+)"', info)
    card = m.group(1) if m else "Unknown"
    if "hdmi" in info.lower() or "hdmi" in card.lower():
        if "vc4-hdmi-0" in info or "vc4hdmi0" in info:
            return "HDMI 1"
        if "vc4-hdmi-1" in info or "vc4hdmi1" in info:
            return "HDMI 2"
        return f"HDMI ({card})"
    return card


def list_sinks():
    """Returns [{"id": str, "name": str, "default": bool}, ...]."""
    try:
        out = subprocess.run(["wpctl", "status"], capture_output=True, text=True, timeout=3, env=_wpctl_env()).stdout
    except Exception:
        return []
    sinks = []
    in_sinks = False
    for line in out.splitlines():
        if "Sinks:" in line:
            in_sinks = True
            continue
        if in_sinks:
            if "Sources:" in line:
                break
            m = re.search(r"(\*?)\s*(\d+)\.\s+(.+?)\s*\[vol", line)
            if m:
                sinks.append({"id": m.group(2), "default": m.group(1) == "*", "raw": line})
    for s in sinks:
        try:
            info = subprocess.run(["wpctl", "inspect", s["id"]], capture_output=True, text=True, timeout=3, env=_wpctl_env()).stdout
        except Exception:
            info = ""
        s["name"] = friendly_name(info)
    return sinks


def set_default_sink(sink_id):
    try:
        subprocess.run(["wpctl", "set-default", sink_id], capture_output=True, timeout=3, env=_wpctl_env())
    except Exception:
        pass


def get_volume():
    try:
        out = subprocess.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
                              capture_output=True, text=True, timeout=2, env=_wpctl_env()).stdout
        parts = out.strip().split()
        vol = int(round(float(parts[1]) * 100)) if len(parts) >= 2 else 0
        muted = "MUTED" in out
        return clamp(vol, 0, 100), muted
    except Exception:
        return 0, False


def set_volume_step(step):
    try:
        sign = "+" if step > 0 else "-"
        subprocess.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{abs(step)}%{sign}"],
                        capture_output=True, timeout=2, env=_wpctl_env())
    except Exception:
        pass


def toggle_mute():
    try:
        subprocess.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"], capture_output=True, timeout=2, env=_wpctl_env())
    except Exception:
        pass


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


CONFIRM_DEBOUNCE_S = 0.25
# Guards confirm/back specifically (not directional movement) against
# switch/contact bounce on cheap arcade buttons and joystick encoders, which
# can report two or more rapid press events for what is physically a single
# tap - without this a bounced confirm press on "mute" could toggle mute on
# and then immediately back off again, which looks to the user like the
# button "did nothing".


def poll_action(stdscr, js_file, axis_state, action_debounce, timeout=0.1):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        action = "confirm"
                    elif number == BTN_BACK:
                        action = "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch == curses.KEY_LEFT:
            return "left"
        if ch == curses.KEY_RIGHT:
            return "right"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


def draw(win, sinks, out_idx, vol, muted, sel, js_connected):
    win.erase()
    h, w = win.getmaxyx()
    title = " AUDIO SETTINGS "
    safe_addstr(win, 1, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)

    top = 5
    for i, key in enumerate(ROWS):
        y = top + i
        is_sel = i == sel
        prefix = "> " if is_sel else "  "
        label = f"{prefix}{ROW_LABELS[key]:<10}"
        if key == "output":
            val = sinks[out_idx]["name"] if sinks else "(no sinks found)"
        elif key == "volume":
            val = f"{vol:>3}%"
        elif key == "mute":
            val = "MUTED" if muted else "off"
        attr = (curses.color_pair(COL_SEL) | curses.A_BOLD) if is_sel else curses.color_pair(COL_LABEL)
        col = max(0, (w // 2) - 20)
        safe_addstr(win, y, col, label, attr)
        safe_addstr(win, y, col + 16, val, attr | (curses.A_BOLD if is_sel else 0))

    vol_w = 24
    vol_filled = int((vol / 100) * vol_w)
    vol_bar = "▮" * vol_filled + "▯" * (vol_w - vol_filled)
    safe_addstr(win, top + len(ROWS) + 2, cx(win, vol_bar), vol_bar, curses.color_pair(COL_HINT))

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 3, cx(win, js_line), js_line, curses.color_pair(COL_GOOD if js_connected else COL_BAD) | curses.A_DIM)

    footer1 = "UP/DOWN: select   LEFT/RIGHT: change/adjust"
    footer2 = "Enter/A/X: apply   ESC/B/Circle: done"
    safe_addstr(win, h - 2, cx(win, footer1), footer1, curses.color_pair(COL_HINT))
    safe_addstr(win, h - 1, cx(win, footer2), footer2, curses.A_DIM)
    win.refresh()


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)
    curses.init_pair(COL_SEL, curses.COLOR_GREEN, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    axis_state = {}
    action_debounce = {}

    sinks = list_sinks()
    out_idx = 0
    for i, s in enumerate(sinks):
        if s.get("default"):
            out_idx = i
            break
    vol, muted = get_volume()
    sel = 0

    try:
        while True:
            draw(stdscr, sinks, out_idx, vol, muted, sel, js_file is not None)
            action = poll_action(stdscr, js_file, axis_state, action_debounce)
            if action is None:
                continue

            if action == "back":
                break
            elif action == "up":
                sel = (sel - 1) % len(ROWS)
            elif action == "down":
                sel = (sel + 1) % len(ROWS)
            else:
                key = ROWS[sel]
                step_dir = 1 if action == "right" else (-1 if action == "left" else 0)
                if key == "output" and sinks:
                    if step_dir:
                        out_idx = (out_idx + step_dir) % len(sinks)
                    if action == "confirm" or step_dir:
                        set_default_sink(sinks[out_idx]["id"])
                        sinks = list_sinks()
                        for i, s in enumerate(sinks):
                            if s.get("default"):
                                out_idx = i
                                break
                elif key == "volume" and step_dir:
                    set_volume_step(step_dir * 5)
                    vol, muted = get_volume()
                elif key == "mute" and action in ("left", "right", "confirm"):
                    toggle_mute()
                    vol, muted = get_volume()
    finally:
        if js_file is not None:
            js_file.close()


def main():
    curses.wrapper(run)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/audio-settings.py"

    touch "$PI_HOME/RetroPie/retropiemenu/avsettings.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "avsettings.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[avsettings] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[avsettings] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}avsettings.rp)\n{indent}    python3 {pi_home}/scripts/audio-settings.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[avsettings] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_wifi_settings_tool() {
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/wifi-settings.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
WiFi settings gate for pi-arcade-setup. Run from the RetroPie menu
("WiFi settings") or directly:
    python3 wifi-settings.py
WiFi setup (entering an SSID/password) needs a real keyboard, so this asks
first rather than silently dropping the controller-only user into a screen
they can't use. Answering "Yes" launches `nmtui` (NetworkManager's text UI)
for the actual configuration.

Confirming here works with the controller (X/Cross toggles the highlighted
answer to Yes) as well as a keyboard, matching the rest of the RetroPie
menu.
"""
import curses
import os
import select
import struct
import sys
import time

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

COL_HEADER, COL_LABEL, COL_HINT, COL_SEL = 1, 2, 3, 4


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


CONFIRM_DEBOUNCE_S = 0.25
# Guards confirm/back specifically (not directional movement) against
# switch/contact bounce on cheap arcade buttons and joystick encoders, which
# can report two or more rapid press events for what is physically a single
# tap - without this a bounced confirm press could immediately re-toggle the
# Yes/No selection back, or fire the confirm/cancel branch twice.


def poll_action(stdscr, js_file, axis_state, action_debounce, timeout=0.15):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        action = "confirm"
                    elif number == BTN_BACK:
                        action = "back"
                elif typ == JS_EVENT_AXIS and number == 0:
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(0, False)
                    axis_state[0] = past
                    if past and not was_past:
                        return "right" if value > 0 else "left"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_LEFT:
            return "left"
        if ch == curses.KEY_RIGHT:
            return "right"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


def draw(win, yes_selected, js_connected):
    win.erase()
    h, w = win.getmaxyx()
    title = " WIFI SETTINGS "
    safe_addstr(win, 2, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)

    q = "Do you have a keyboard plugged in?"
    safe_addstr(win, h // 2 - 2, cx(win, q), q, curses.color_pair(COL_LABEL) | curses.A_BOLD)
    note = "WiFi setup needs one to type your network name and password."
    safe_addstr(win, h // 2 - 1, cx(win, note), note, curses.A_DIM)

    yes_attr = (curses.color_pair(COL_SEL) | curses.A_BOLD | curses.A_REVERSE) if yes_selected else curses.color_pair(COL_LABEL)
    no_attr = (curses.color_pair(COL_SEL) | curses.A_BOLD | curses.A_REVERSE) if not yes_selected else curses.color_pair(COL_LABEL)
    options = "  Yes  " + "   " + "  No  "
    mid = h // 2 + 1
    yes_x = cx(win, options)
    safe_addstr(win, mid, yes_x, "  Yes  ", yes_attr)
    safe_addstr(win, mid, yes_x + 10, "  No  ", no_attr)

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 3, cx(win, js_line), js_line, curses.A_DIM)

    footer = "LEFT/RIGHT: choose   Enter/A/X: confirm   ESC/B/Circle: cancel"
    safe_addstr(win, h - 2, cx(win, footer), footer, curses.color_pair(COL_HINT))
    win.refresh()


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_SEL, curses.COLOR_GREEN, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    axis_state = {}
    action_debounce = {}
    yes_selected = True

    result = False
    try:
        while True:
            draw(stdscr, yes_selected, js_file is not None)
            action = poll_action(stdscr, js_file, axis_state, action_debounce)
            if action is None:
                continue
            if action == "back":
                result = False
                break
            if action in ("left", "right"):
                yes_selected = not yes_selected
            if action == "confirm":
                result = yes_selected
                break
    finally:
        if js_file is not None:
            js_file.close()

    return result


def main():
    has_keyboard = curses.wrapper(run)
    if has_keyboard:
        os.execvp("nmtui", ["nmtui"])
    else:
        print()
        print("Plug in a keyboard and reopen WiFi settings to configure WiFi.")


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/wifi-settings.py"

    touch "$PI_HOME/RetroPie/retropiemenu/wifigate.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "wifigate.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[wifigate] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[wifigate] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}wifigate.rp)\n{indent}    python3 {pi_home}/scripts/wifi-settings.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[wifigate] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_ftp_settings_tool() {
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/ftp-settings.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
File transfer settings for pi-arcade-setup. Run from the RetroPie menu
("FTP settings") or directly:
    python3 ftp-settings.py
Two independently switchable file-transfer methods:
  - FTP: the proftpd service pi-arcade-setup installs (port 21).
  - SFTP: file transfer over the SSH connection you already use to manage
    the Pi (port 22). This does NOT touch the ssh service itself - sshd
    stays up the whole time, since that's this project's only remote
    shell/management path - it only enables or disables the "sftp"
    subsystem sshd exposes, by commenting/restoring the Subsystem line in
    /etc/ssh/sshd_config and reloading (not restarting) sshd, which
    re-reads config without dropping any existing session.

Fully navigable by controller as well as keyboard: left stick (or D-pad)
up/down to choose FTP or SFTP, X/Cross to toggle it on/off, Circle/B to
exit - same button roles as the rest of the RetroPie menu.
"""
import curses
import re
import select
import struct
import subprocess
import sys
import time

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_AXIS = 0x02
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
AXIS_THRESHOLD = 16000
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

FTP_SERVICE = "proftpd"
SSHD_CONFIG = "/etc/ssh/sshd_config"
# Matches an (optionally already-commented) "Subsystem sftp ..." line,
# tabs or spaces, so both the stock Debian config's tab-separated form and
# a hand-edited space-separated one are recognized the same way.
SFTP_LINE_RE = re.compile(r"^([ \t]*)#?[ \t]*(Subsystem[ \t]+sftp\b.*)$", re.MULTILINE)

ROWS = ["ftp", "sftp"]
ROW_LABELS = {"ftp": "FTP  (ProFTPD, port 21)", "sftp": "SFTP (over SSH, port 22)"}

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD, COL_SEL = 1, 2, 3, 4, 5, 6

CONFIRM_DEBOUNCE_S = 0.25
# Secondary safety net for the keyboard path only (curses getch() in this
# raw mode has no reliable key-up signal, so a held key can't be tracked
# as a press/release edge the way a joystick button can below).


def cx(win, text):
    _, w = win.getmaxyx()
    return max(0, (w - len(text)) // 2)


def safe_addstr(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h:
        try:
            win.addstr(y, max(0, x), text[: max(0, w - x - 1)], attr)
        except curses.error:
            pass


def ftp_is_enabled():
    try:
        r = subprocess.run(["systemctl", "is-enabled", FTP_SERVICE], capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "enabled"
    except Exception:
        return False


def ftp_is_active():
    try:
        r = subprocess.run(["systemctl", "is-active", FTP_SERVICE], capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "active"
    except Exception:
        return False


def set_ftp_enabled(enable):
    if enable:
        subprocess.run(["sudo", "systemctl", "enable", "--now", FTP_SERVICE], capture_output=True, timeout=10)
    else:
        subprocess.run(["sudo", "systemctl", "disable", "--now", FTP_SERVICE], capture_output=True, timeout=10)


def sftp_is_enabled():
    try:
        with open(SSHD_CONFIG) as f:
            text = f.read()
    except Exception:
        return False
    m = SFTP_LINE_RE.search(text)
    if not m:
        return False
    # group(0) is the whole matched line; an active (uncommented) line is
    # one where nothing but the leading whitespace in group(1) precedes
    # "Subsystem" - i.e. the match doesn't start with a '#' after that.
    line = m.group(0).strip()
    return not line.startswith("#")


def sftp_is_active():
    # sshd itself is never toggled by this tool (SSH shell access must
    # always stay available), so "active" tracks the same thing as
    # "enabled" here, unlike proftpd's separate enabled/active split.
    return sftp_is_enabled()


def set_sftp_enabled(enable):
    script = (
        "import re\n"
        "path = " + repr(SSHD_CONFIG) + "\n"
        "with open(path) as f:\n"
        "    text = f.read()\n"
        "pattern = re.compile(r'^([ \\t]*)#?[ \\t]*(Subsystem[ \\t]+sftp\\b.*)$', re.MULTILINE)\n"
        "if pattern.search(text):\n"
        "    if " + repr(bool(enable)) + ":\n"
        "        text = pattern.sub(lambda m: m.group(1) + m.group(2), text, count=1)\n"
        "    else:\n"
        "        text = pattern.sub(lambda m: m.group(1) + '# ' + m.group(2), text, count=1)\n"
        "elif " + repr(bool(enable)) + ":\n"
        "    sep = '' if text.endswith(chr(10)) else chr(10)\n"
        "    text += sep + 'Subsystem sftp /usr/lib/openssh/sftp-server' + chr(10)\n"
        "with open(path, 'w') as f:\n"
        "    f.write(text)\n"
    )
    try:
        subprocess.run(["sudo", "python3", "-c", script], capture_output=True, timeout=5)
        subprocess.run(["sudo", "systemctl", "reload", "ssh"], capture_output=True, timeout=10)
    except Exception:
        pass


def is_enabled(row):
    return ftp_is_enabled() if row == "ftp" else sftp_is_enabled()


def is_active(row):
    return ftp_is_active() if row == "ftp" else sftp_is_active()


def set_enabled(row, enable):
    if row == "ftp":
        set_ftp_enabled(enable)
    else:
        set_sftp_enabled(enable)


def get_ip():
    try:
        r = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3)
        return r.stdout.strip().split()[0] if r.stdout.strip() else "?"
    except Exception:
        return "?"


def open_joystick():
    try:
        return open(JS_DEVICE, "rb")
    except (FileNotFoundError, OSError):
        return None


def poll_action(stdscr, js_file, axis_state, button_state, action_debounce, timeout=0.15):
    """button_state tracks whether BTN_CONFIRM/BTN_BACK are currently held,
    so an action only fires on the press edge (0->1) - some controllers/
    drivers report a repeat "still held" button-down event for what a
    person experiences as a single tap, and requiring an intervening
    release is correct regardless of timing, unlike a fixed debounce
    window (still kept below as a secondary net for the keyboard path)."""
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    action = None

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and number in (BTN_CONFIRM, BTN_BACK):
                    was_held = button_state.get(number, False)
                    button_state[number] = bool(value)
                    if value == 1 and not was_held:
                        if number == BTN_CONFIRM:
                            action = "confirm"
                        elif number == BTN_BACK:
                            action = "back"
                elif typ == JS_EVENT_AXIS and number == 1:
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(1, False)
                    axis_state[1] = past
                    if past and not was_past:
                        return "down" if value > 0 else "up"

    if action is None and sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch in (10, 13, ord(" ")):
            action = "confirm"
        elif ch in (27, ord("q"), ord("Q")):
            action = "back"

    if action in ("confirm", "back"):
        now = time.monotonic()
        if now - action_debounce.get(action, 0.0) < CONFIRM_DEBOUNCE_S:
            return None
        action_debounce[action] = now

    return action


def settle_input(stdscr, js_file, duration=0.5):
    """Discards any keyboard/joystick input that arrives during the
    settle window right after toggling a service, so a lingering
    duplicate from the same physical press can't be misread as a second,
    unintended toggle once the loop resumes."""
    deadline = time.monotonic() + duration
    fds = [sys.stdin] + ([js_file] if js_file is not None else [])
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            ready, _, _ = select.select(fds, [], [], remaining)
        except (OSError, ValueError):
            break
        if not ready:
            break
        if js_file is not None and js_file in ready:
            js_file.read(EVENT_SIZE)
        if sys.stdin in ready:
            stdscr.getch()


def draw(win, states, sel, busy_row, js_connected):
    win.erase()
    h, w = win.getmaxyx()
    title = " FILE TRANSFER SETTINGS "
    safe_addstr(win, 1, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)

    top = h // 2 - 4
    for i, row in enumerate(ROWS):
        y = top + i * 3
        enabled, active = states[row]
        status = "ON" if enabled else "OFF"
        status_attr = curses.color_pair(COL_GOOD) if enabled else curses.color_pair(COL_BAD)
        sel_attr = curses.A_REVERSE if i == sel else 0

        label_line = f"{ROW_LABELS[row]}"
        safe_addstr(win, y, cx(win, label_line), label_line, curses.color_pair(COL_LABEL) | sel_attr | curses.A_BOLD)

        if busy_row == row:
            status_line = "Applying..."
            status_attr = curses.color_pair(COL_HINT)
        elif row == "ftp" and enabled and not active:
            status_line = f"{status} (enabled but not running yet)"
        else:
            status_line = status
        safe_addstr(win, y + 1, cx(win, status_line), status_line, status_attr | curses.A_BOLD)

    ip = get_ip()
    hint_y = top + len(ROWS) * 3 + 1
    if states["ftp"][0]:
        safe_addstr(win, hint_y, cx(win, f"FTP:  ftp://{ip}"), f"FTP:  ftp://{ip}", curses.color_pair(COL_LABEL))
        hint_y += 1
    if states["sftp"][0]:
        safe_addstr(win, hint_y, cx(win, f"SFTP: sftp://{ip}"), f"SFTP: sftp://{ip}", curses.color_pair(COL_LABEL))
        hint_y += 1

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 3, cx(win, js_line), js_line, curses.A_DIM)

    footer = "UP/DOWN: select   Enter/A/X: toggle on/off   ESC/B/Circle: exit"
    safe_addstr(win, h - 2, cx(win, footer), footer, curses.color_pair(COL_HINT))
    win.refresh()


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)
    curses.init_pair(COL_SEL, curses.COLOR_GREEN, -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    axis_state = {}
    button_state = {}
    action_debounce = {}
    sel = 0
    states = {row: (is_enabled(row), is_active(row)) for row in ROWS}

    try:
        while True:
            draw(stdscr, states, sel, None, js_file is not None)
            action = poll_action(stdscr, js_file, axis_state, button_state, action_debounce)
            if action is None:
                continue

            if action == "back":
                break
            elif action == "up":
                sel = (sel - 1) % len(ROWS)
            elif action == "down":
                sel = (sel + 1) % len(ROWS)
            elif action == "confirm":
                row = ROWS[sel]
                draw(stdscr, states, sel, row, js_file is not None)
                enabled, _ = states[row]
                set_enabled(row, not enabled)
                states[row] = (is_enabled(row), is_active(row))
                settle_input(stdscr, js_file)
    finally:
        if js_file is not None:
            js_file.close()


def main():
    curses.wrapper(run)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/ftp-settings.py"

    touch "$PI_HOME/RetroPie/retropiemenu/ftpsettings.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "ftpsettings.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[ftpsettings] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
case_end = text.find(";;", idx)
if case_end == -1:
    print("[ftpsettings] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}ftpsettings.rp)\n{indent}    python3 {pi_home}/scripts/ftp-settings.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[ftpsettings] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

# MAME's own stock combo for its in-game Show/Hide Menu is Select+X to
# open, Select+Start to cancel - but Select+Start is also this project's
# own quit-to-frontend shortcut (input_quit_gamepad_combo=4, see
# phase_video_rotation_setup), so this defaults the combo to L3+R3 instead
# (unconditionally bound to JOYCODE_1_BUTTON7/BUTTON8 regardless of
# controller/profile - see the README's Known limitations entry on MAME's
# menu hotkey for why L3+R3 specifically). Written into roms/arcade/mame/
# cfg/default.cfg - this phase only sets the untouched fresh-install
# default, never overwrites a choice already made in-game (MAME's own
# "Input (general)" menu lets you re-capture this combo any time). This
# combo opens MAME's own stock in-game menu (save states, DIP switches,
# etc.) - unchanged, still MAME's normal nested menu tree; the Audio Boost
# and Stereo/Mono controls live as libretro core options instead (see
# ENABLE_MAME_ARCADE_AUDIO_OPTIONS above), reachable from RetroArch's own
# Quick Menu (Home button) rather than from this combo.
#
# This used to also open a custom in-game overlay hijacking this same
# combo, and before that a whole standalone "MAME Audio Mixer Hotkey"
# RetroPie-menu tool - both superseded by the RetroArch Quick Menu
# integration above. Only the unconditional fresh-install L3+R3 default
# remains here, plus cleanup of that older tool's leftovers on a re-run
# against an existing install.
phase_mame_menu_hotkey_default() {
    rm -f "$PI_HOME/scripts/mame-mixer-hotkey.py" "$PI_HOME/RetroPie/retropiemenu/mamemixerhotkey.rp"

    # A previous run of this script (before this tool was folded into
    # "Hotkey Config") may have wired a mamemixerhotkey.rp) case into
    # retropiemenu.sh - harmless dead code now that the .rp stub and
    # gamelist entry are both gone, but clean it up for hygiene.
    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && grep -q "mamemixerhotkey.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
block = f"        mamemixerhotkey.rp)\n            python3 {pi_home}/scripts/mame-mixer-hotkey.py\n            ;;\n"
if block in text:
    open(path, "w").write(text.replace(block, ""))
    print("[mame-menu-hotkey] removed stale mamemixerhotkey.rp) case from retropiemenu.sh")
else:
    print("[mame-menu-hotkey] mamemixerhotkey.rp) case present but didn't match expected indentation/text exactly; left as-is (harmless dead code)")
PYEOF
    fi

    mkdir -p "$PI_HOME/RetroPie/roms/arcade/mame/cfg"
    python3 - <<MENUHOTKEYEOF
import os
import shutil
import xml.etree.ElementTree as ET

ROMS_DIR = "$PI_HOME/RetroPie/roms/arcade"
CFG_DIR = os.path.join(ROMS_DIR, "mame", "cfg")
DEFAULT_CFG_PATH = os.path.join(CFG_DIR, "default.cfg")
MENU_HOTKEY_TOKEN = "JOYCODE_1_BUTTON7 JOYCODE_1_BUTTON8"


def load_default_cfg():
    if os.path.isfile(DEFAULT_CFG_PATH):
        try:
            tree = ET.parse(DEFAULT_CFG_PATH)
            system = tree.getroot().find("system")
            if system is None:
                system = ET.SubElement(tree.getroot(), "system")
                system.set("name", "default")
            return tree, system
        except ET.ParseError:
            pass
    root = ET.Element("mameconfig")
    root.set("version", "10")
    system = ET.SubElement(root, "system")
    system.set("name", "default")
    return ET.ElementTree(root), system


def write_default_cfg(tree):
    try:
        ET.indent(tree, space="    ")
    except Exception:
        pass
    os.makedirs(CFG_DIR, exist_ok=True)
    try:
        if os.path.exists(DEFAULT_CFG_PATH):
            shutil.copy2(DEFAULT_CFG_PATH, DEFAULT_CFG_PATH + ".bak")
    except OSError:
        pass
    body = ET.tostring(tree.getroot(), encoding="unicode")
    content = (
        "ï»¿<?xml version=\"1.0\"?>\n"
        "<!-- This file is autogenerated; comments and unknown tags will be stripped -->\n"
        + body + "\n"
    )
    tmp = DEFAULT_CFG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, DEFAULT_CFG_PATH)


tree, system = load_default_cfg()
inp = system.find("input")
already_set = False
if inp is not None:
    for port in inp.findall("port"):
        if port.get("type") in ("UI_MENU", "UI_CANCEL"):
            already_set = True
            break

if already_set:
    print("[mame-menu-hotkey] default.cfg already has a UI_MENU/UI_CANCEL override, leaving as-is")
else:
    if inp is None:
        inp = ET.SubElement(system, "input")
    for ptype in ("UI_MENU", "UI_CANCEL"):
        port = ET.SubElement(inp, "port")
        port.set("type", ptype)
        seq = ET.SubElement(port, "newseq")
        seq.set("type", "standard")
        seq.text = MENU_HOTKEY_TOKEN
    write_default_cfg(tree)
    print("[mame-menu-hotkey] set MAME internal-menu combo to L3+R3 (avoids the Select+Start clash with this project's quit-to-frontend shortcut)")
MENUHOTKEYEOF

    log "MAME Show/Hide Menu combo defaulted to L3+R3 in roms/arcade/mame/cfg/default.cfg (avoids the Select+Start clash with this project's quit-to-frontend shortcut). Opens MAME's own stock in-game menu; Audio Boost/Stereo-Mono are now RetroArch Quick Menu (Home button) options instead - see ENABLE_MAME_ARCADE_AUDIO_OPTIONS."
    return 0
}

# Installs thebezelproject/BezelProject's bezelproject.sh exactly the way
# its own README says to (a single script dropped into the RetroPie menu
# folder) - no separate case-statement wiring into retropiemenu.sh is
# needed here, unlike this project's other custom tools, since the
# "retropie" custom system's <extension> already includes .sh directly
# (RetroPie's own retropiemenu dispatch runs a .sh file placed there as-is;
# the .rp "stub + case in retropiemenu.sh" mechanism used elsewhere in this
# script is only needed for tools that aren't already a standalone script).
# The gamelist entry for this is added unconditionally inside
# phase_custom_retropie_system (gated on ENABLE_BEZEL_PROJECT there too);
# this phase only needs to actually place the file.
phase_bezel_project_install() {
    if [ "$ENABLE_BEZEL_PROJECT" != "true" ]; then
        log "ENABLE_BEZEL_PROJECT=false, skipping"
        return 0
    fi
    mkdir -p "$PI_HOME/RetroPie/retropiemenu"
    if curl -fsSL "https://raw.githubusercontent.com/thebezelproject/BezelProject/master/bezelproject.sh" \
        -o "$PI_HOME/RetroPie/retropiemenu/bezelproject.sh"; then
        chmod +x "$PI_HOME/RetroPie/retropiemenu/bezelproject.sh"
        chown "$PI_USER:$PI_USER" "$PI_HOME/RetroPie/retropiemenu/bezelproject.sh"
        log "Bezel Project installed - run it from the RetroPie Setup menu to browse and download per-system overlay bezel packs (read the README's Known limitations note before enabling the arcade/MAME pack)"
    else
        log_warn "Bezel Project download failed; 'Bezel Project' menu entry will fail to launch until you re-run this phase or fetch bezelproject.sh manually"
    fi
    return 0
}

phase_finalize() {
    log ""
    log "========================================================"
    log " pi-arcade-setup complete."
    log " Frontend: $(cat "$PI_HOME/.frontend" 2>/dev/null || echo "$INITIAL_FRONTEND") (switch with ~/switch-frontend.sh [esde|classic])"
    log " ROMs go in: $PI_HOME/RetroPie/roms/<system>/"
    log " Log: $LOG_FILE"
    log "========================================================"
    remove_resume_service
    if [ "$AUTO_REBOOT_AT_END" = "true" ]; then
        log "Rebooting into the arcade UI in 5 seconds..."
        sleep 5
        sudo systemctl reboot
    fi
    return 0
}

# --------------------------------------------------------------------------
# 3. Main
# --------------------------------------------------------------------------

main() {
    # Resumed runs (via systemd) load config saved by the original run so
    # the same settings are used across reboots.
    if [ "${1:-}" = "--resume" ] && [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    PHASES=(
        preflight
        overclock
        base_update
        display_setup
        verify_display
        retropie_install
        gcc14_cflags_patch
        emulators_install
        mame_arcade_overlay_build
        dreamcast_flycast_install
        gamecube_install
        retroarch_menu_rotation_patch
        retroarch_autoconfig
        video_rotation_setup
        ftp_install
        disk_cleanup
        esde_build_deps
        esde_build
        esde_config
        esde_retroarch_links
        esde_default_emulators
        themes_install
        theme_system_art
        autostart_setup
        custom_retropie_system
        splash_setup
        polkit_fix
        led_strip_setup
        led_config_tool
        audio_output_setup
        music_player_setup
        bt_speaker_setup
        bt_pair_tool
        bt_player_tool
        audio_settings_tool
        wifi_settings_tool
        ftp_settings_tool
        mame_menu_hotkey_default
        bezel_project_install
        finalize
    )

    for phase in "${PHASES[@]}"; do
        run_phase "$phase"
    done

    log "All phases complete."
}

main "$@"
