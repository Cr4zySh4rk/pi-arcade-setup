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

# --- Emulators --------------------------------------------------------------
# MAME is always installed (the point of this script). Additional cores are
# a comma-separated list of RetroPie-Setup package ids.
EMULATOR_CORES="${EMULATOR_CORES:-lr-snes9x,lr-pcsx-rearmed,ppsspp,lr-fceumm,lr-gambatte,lr-genesis-plus-gx,lr-nestopia,lr-picodrive,mupen64plus}"

# --- ES-DE --------------------------------------------------------------
ESDE_BRANCH="${ESDE_BRANCH:-stable-3.4}"
APPLY_ESDE_QUITMENU_PATCH="${APPLY_ESDE_QUITMENU_PATCH:-true}"
INSTALL_THEMES="${INSTALL_THEMES:-true}"
ESDE_THEME_NAME="${ESDE_THEME_NAME:-artflix-revisited}"
INITIAL_FRONTEND="${INITIAL_FRONTEND:-esde}"            # esde | classic
# Console autologin + boot-time launch trigger (RetroPie's own "autostart"
# module - see phase_autostart_setup). Off only makes sense if you intend
# to wire up autostart some other way yourself.
ENABLE_CONSOLE_AUTOSTART="${ENABLE_CONSOLE_AUTOSTART:-true}"

# --- Controller hotkeys (brightness/volume) ------------------------------
# Safe to leave on for generic hardware: the daemon auto-detects the
# backlight path, no-ops gracefully if no controller/backlight is present,
# and the button numbers below can be re-captured at any time from the
# in-frontend "Hotkey Config" tool this script installs (see README).
ENABLE_CONTROLLER_HOTKEYS="${ENABLE_CONTROLLER_HOTKEYS:-true}"
ALSA_CARD_INDEX="${ALSA_CARD_INDEX:-0}"
# Pins the aux/headphone jack as the default PipeWire/WirePlumber audio
# output (see phase_audio_output_setup) - this build has no HDMI-audio
# display, so HDMI should never be picked as the output even if something
# later gets plugged into it.
ENABLE_AUX_AUDIO_FORCE="${ENABLE_AUX_AUDIO_FORCE:-true}"
BTN_L3="${BTN_L3:-9}"
BTN_R3="${BTN_R3:-10}"
BTN_SQUARE="${BTN_SQUARE:-2}"
BTN_X="${BTN_X:-0}"
BTN_CIRCLE="${BTN_CIRCLE:-1}"
BTN_TRIANGLE="${BTN_TRIANGLE:-3}"
HOTKEY_STEP="${HOTKEY_STEP:-5}"

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

# --- Bluetooth speaker ---------------------------------------------------------
# Turns the Pi into an always-on A2DP sink advertised as BT_SPEAKER_NAME, via
# PipeWire/WirePlumber's native Bluetooth module (already the default audio
# stack on this OS image - see phase_bt_speaker_setup for why bluealsa/
# PulseAudio aren't used instead) plus a headless auto-accept pairing agent.
# RetroPie menu -> "Bluetooth Audio" shows AVRCP now-playing metadata from
# the connected phone and can send it play/pause/next/prev, car-head-unit
# style. The A2DP sink itself keeps running in the background regardless of
# whether that tool is open, same as the LED strip daemon.
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
SPLASH_TRANSFORM_TYPE=$SPLASH_TRANSFORM_TYPE
SPLASH_VIDEO_URL=$SPLASH_VIDEO_URL
DO_RPI_FIRMWARE_UPDATE=$DO_RPI_FIRMWARE_UPDATE
EMULATOR_CORES=$EMULATOR_CORES
ESDE_BRANCH=$ESDE_BRANCH
APPLY_ESDE_QUITMENU_PATCH=$APPLY_ESDE_QUITMENU_PATCH
INSTALL_THEMES=$INSTALL_THEMES
ESDE_THEME_NAME=$ESDE_THEME_NAME
INITIAL_FRONTEND=$INITIAL_FRONTEND
ENABLE_CONSOLE_AUTOSTART=$ENABLE_CONSOLE_AUTOSTART
ENABLE_CONTROLLER_HOTKEYS=$ENABLE_CONTROLLER_HOTKEYS
ALSA_CARD_INDEX=$ALSA_CARD_INDEX
ENABLE_AUX_AUDIO_FORCE=$ENABLE_AUX_AUDIO_FORCE
BTN_L3=$BTN_L3
BTN_R3=$BTN_R3
BTN_SQUARE=$BTN_SQUARE
BTN_X=$BTN_X
BTN_CIRCLE=$BTN_CIRCLE
BTN_TRIANGLE=$BTN_TRIANGLE
HOTKEY_STEP=$HOTKEY_STEP
ENABLE_LED_STRIP=$ENABLE_LED_STRIP
LED_GPIO_PIN=$LED_GPIO_PIN
LED_COUNT=$LED_COUNT
LED_COUNT_MAX=$LED_COUNT_MAX
LED_DMA_CHANNEL=$LED_DMA_CHANNEL
LED_PWM_CHANNEL=$LED_PWM_CHANNEL
ENABLE_MUSIC_PLAYER=$ENABLE_MUSIC_PLAYER
MUSIC_DIR=$MUSIC_DIR
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
    sudo ./retropie_packages.sh setup basic_install || die "RetroPie basic_install failed"
    [ -x /opt/retropie/supplementary/emulationstation/emulationstation ] || command -v emulationstation >/dev/null 2>&1 || log_warn "emulationstation binary not found where expected after basic_install"
    return 0
}

phase_emulators_install() {
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    log "Installing MAME (lr-mame)"
    sudo ./retropie_packages.sh lr-mame _binary_ || die "lr-mame install failed"

    local core sys
    IFS=',' read -ra cores <<< "$EMULATOR_CORES"
    for core in "${cores[@]}"; do
        [ -z "$core" ] && continue
        log "Installing emulator core: $core"
        sudo ./retropie_packages.sh "$core" _binary_
        # retropie_packages.sh can exit non-zero on a non-fatal post-install
        # step (e.g. gamelist/scriptmodule bookkeeping) even though the
        # package itself installed fine - so don't trust the exit code
        # alone. Only actually warn if nothing landed on disk for it.
        if [ ! -d "/opt/retropie/libretrocores/$core" ] && [ ! -d "/opt/retropie/emulators/$core" ]; then
            log_warn "$core does not appear to be installed (this is a known flaky step for some cores, e.g. mupen64plus/N64 upstream) - continuing without it"
        fi
    done

    for sys in snes psx psp arcade nes gb gbc megadrive n64; do
        mkdir -p "$PI_HOME/RetroPie/roms/$sys"
    done
    return 0
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
    _set_retroarch_key "$all_cfg" "video_allow_rotate" "true"
    _set_retroarch_key "$all_cfg" "video_rotation" "$RETROARCH_VIDEO_ROTATION"

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
        log "Set video_allow_rotate=true, video_rotation=$RETROARCH_VIDEO_ROTATION in all/retroarch.cfg and arcade/retroarch.cfg"
    else
        log_warn "arcade/retroarch.cfg not found yet - set video_allow_rotate/video_rotation in all/retroarch.cfg only; the arcade system will still inherit it via #include"
    fi
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
    declare -A core_so=(
        [lr-snes9x]=snes9x
        [lr-pcsx-rearmed]=pcsx_rearmed
        [lr-fceumm]=fceumm
        [lr-gambatte]=gambatte
        [lr-genesis-plus-gx]=genesis_plus_gx
        [lr-nestopia]=nestopia
        [lr-picodrive]=picodrive
        [mupen64plus]=mupen64plus_next
    )
    local core cores
    IFS=',' read -ra cores <<< "$EMULATOR_CORES"
    for core in "${cores[@]}"; do
        local so="${core_so[$core]:-}"
        [ -z "$so" ] && continue
        local src="/opt/retropie/libretrocores/${core}/${so}_libretro.so"
        if [ -f "$src" ]; then
            ln -sf "$src" "$PI_HOME/.config/retroarch/cores/${so}_libretro.so"
        fi
    done

    # RetroPie's lr-mame ships as mamearcade_libretro.so; ES-DE's find-rules
    # expect mame_libretro.so.
    local mame_src="/opt/retropie/libretrocores/lr-mame/mamearcade_libretro.so"
    if [ -f "$mame_src" ]; then
        ln -sf "$mame_src" "$PI_HOME/.config/retroarch/cores/mame_libretro.so"
    else
        log_warn "mamearcade_libretro.so not found; MAME may not be picked up by ES-DE yet"
    fi
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
        # Without this, the Pi boots to a plain login prompt and nothing
        # ever launches the frontend.
        sudo raspi-config nonint do_boot_behaviour B2 || log_warn "Could not set console autologin via raspi-config"
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
$( [ "$ENABLE_BT_SPEAKER" = "true" ] && cat <<BTPAIR
	<game>
		<path>./btpair.rp</path>
		<name>Bluetooth</name>
		<desc>Scan for and pair wireless controllers (or any Bluetooth device) - just select one and press confirm, pairing is accepted automatically.</desc>
		<image>$icon_dir/bluetooth.png</image>
	</game>
BTPAIR
)
$( [ "$ENABLE_CONTROLLER_HOTKEYS" = "true" ] && cat <<HOTKEY
	<game>
		<path>./hotkeyconfig.rp</path>
		<name>Hotkey Config</name>
		<desc>Map the controller buttons used for the L3+R3 brightness and volume hotkeys. Press each button twice to confirm.</desc>
		<image>$icon_dir/configedit.png</image>
	</game>
HOTKEY
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
		<desc>Pair a phone to "$BT_SPEAKER_NAME" and stream music to the arcade's speakers. Shows the connected device's now-playing track, car-stereo style, and lets the controller play/pause/skip.</desc>
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
		<desc>Turn the FTP file transfer server on or off.</desc>
		<image>$icon_dir/filemanager.png</image>
	</game>
</gameList>
EOF
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

phase_controller_hotkeys() {
    if [ "$ENABLE_CONTROLLER_HOTKEYS" != "true" ]; then
        log "ENABLE_CONTROLLER_HOTKEYS=false, skipping"
        return 0
    fi
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/controller-hotkeys.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
System-wide controller hotkey daemon for brightness/volume control.
Generated by pi-arcade-setup (https://github.com/Cr4zySh4rk/pi-arcade-setup).

Reads raw joystick events from /dev/input/js0. Works regardless of what has
input focus (EmulationStation, RetroArch in-game, RetroPie-Setup tools).

Controls (hold L3 + R3, then press):
  Square   -> brightness +STEP% (max 100%)
  X        -> brightness -STEP% (min 5%)
  Triangle -> volume +STEP% (max 100%)
  Circle   -> volume -STEP% (min 0%)

Button numbers are loaded from $PI_HOME/.controller-hotkeys-buttons.json if
present (written by the in-frontend "Hotkey Config" tool / hotkey-remap.py),
falling back to the defaults below otherwise.
"""
import glob
import json
import os
import struct
import subprocess
import time

JS_DEVICE = "/dev/input/js0"
STATE_FILE = "$PI_HOME/.controller-hotkeys-state.json"
BUTTON_CONFIG_FILE = "$PI_HOME/.controller-hotkeys-buttons.json"
BACKLIGHT_MAX = 255
ALSA_CARD = "$ALSA_CARD_INDEX"
ALSA_CONTROL = "PCM"
STEP = $HOTKEY_STEP
BRIGHTNESS_MIN = 5
BRIGHTNESS_MAX = 100
VOLUME_MIN = 0
VOLUME_MAX = 100

DEFAULT_BUTTONS = {
    "l3": $BTN_L3, "r3": $BTN_R3,
    "square": $BTN_SQUARE, "x": $BTN_X, "circle": $BTN_CIRCLE, "triangle": $BTN_TRIANGLE,
}

JS_EVENT_BUTTON = 0x01
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)


def load_button_mapping():
    mapping = dict(DEFAULT_BUTTONS)
    if os.path.exists(BUTTON_CONFIG_FILE):
        try:
            with open(BUTTON_CONFIG_FILE) as f:
                data = json.load(f)
                for key in DEFAULT_BUTTONS:
                    if key in data:
                        mapping[key] = data[key]
        except Exception:
            pass
    return mapping


def find_backlight_path():
    matches = glob.glob("/sys/class/backlight/*/brightness")
    return matches[0] if matches else None


BACKLIGHT_PATH = find_backlight_path()


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def load_state():
    brightness = 100
    volume = 78
    if BACKLIGHT_PATH:
        try:
            with open(BACKLIGHT_PATH) as f:
                raw = int(f.read().strip())
                brightness = clamp(round(raw / BACKLIGHT_MAX * 100), BRIGHTNESS_MIN, BRIGHTNESS_MAX)
        except Exception:
            pass
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                data = json.load(f)
                brightness = data.get("brightness", brightness)
                volume = data.get("volume", volume)
        except Exception:
            pass
    return {"brightness": brightness, "volume": volume}


def save_state(state):
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


def set_brightness(percent):
    if not BACKLIGHT_PATH:
        return
    raw = round(percent / 100 * BACKLIGHT_MAX)
    try:
        with open(BACKLIGHT_PATH, "w") as f:
            f.write(str(raw))
    except Exception as e:
        print(f"[hotkeys] failed to set brightness: {e}")


def set_volume(percent):
    try:
        subprocess.run(
            ["amixer", "-c", ALSA_CARD, "sset", ALSA_CONTROL, f"{percent}%", "unmute"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
    except Exception as e:
        print(f"[hotkeys] failed to set volume: {e}")


def main():
    buttons = load_button_mapping()
    state = load_state()
    set_brightness(state["brightness"])
    print(f"[hotkeys] starting, brightness={state['brightness']}% volume={state['volume']}% backlight={BACKLIGHT_PATH}")
    print(f"[hotkeys] button mapping: L3={buttons['l3']} R3={buttons['r3']} Square={buttons['square']} "
          f"X={buttons['x']} Circle={buttons['circle']} Triangle={buttons['triangle']}")

    held = {}

    while True:
        try:
            with open(JS_DEVICE, "rb") as js:
                print("[hotkeys] connected to", JS_DEVICE)
                while True:
                    data = js.read(EVENT_SIZE)
                    if not data or len(data) < EVENT_SIZE:
                        break
                    _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
                    if typ & JS_EVENT_INIT:
                        typ &= ~JS_EVENT_INIT
                    if typ != JS_EVENT_BUTTON:
                        continue

                    held[number] = bool(value)
                    if not (held.get(buttons["l3"]) and held.get(buttons["r3"])):
                        continue
                    if not value:
                        continue

                    changed = False
                    if number == buttons["square"]:
                        state["brightness"] = clamp(state["brightness"] + STEP, BRIGHTNESS_MIN, BRIGHTNESS_MAX)
                        set_brightness(state["brightness"]); changed = True
                    elif number == buttons["x"]:
                        state["brightness"] = clamp(state["brightness"] - STEP, BRIGHTNESS_MIN, BRIGHTNESS_MAX)
                        set_brightness(state["brightness"]); changed = True
                    elif number == buttons["triangle"]:
                        state["volume"] = clamp(state["volume"] + STEP, VOLUME_MIN, VOLUME_MAX)
                        set_volume(state["volume"]); changed = True
                    elif number == buttons["circle"]:
                        state["volume"] = clamp(state["volume"] - STEP, VOLUME_MIN, VOLUME_MAX)
                        set_volume(state["volume"]); changed = True

                    if changed:
                        save_state(state)
                        print(f"[hotkeys] brightness={state['brightness']}% volume={state['volume']}%")
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"[hotkeys] joystick read error: {e}")

        held.clear()
        time.sleep(2)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/controller-hotkeys.py"

    sudo tee /etc/systemd/system/controller-hotkeys.service >/dev/null <<EOF
[Unit]
Description=Controller hotkey daemon (L3+R3 brightness/volume)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u $PI_HOME/scripts/controller-hotkeys.py
Restart=always
RestartSec=2
User=root
StandardOutput=append:/var/log/controller-hotkeys.log
StandardError=append:/var/log/controller-hotkeys.log

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now controller-hotkeys.service
    return 0
}

phase_hotkey_remap_tool() {
    if [ "$ENABLE_CONTROLLER_HOTKEYS" != "true" ]; then
        return 0
    fi
    mkdir -p "$PI_HOME/scripts"
    tee "$PI_HOME/scripts/hotkey-remap.py" >/dev/null <<PYEOF
#!/usr/bin/env python3
"""
Interactive controller button-mapping tool for the L3+R3 brightness/volume
hotkey daemon. Run from the RetroPie menu ("Hotkey Config") or directly:
    sudo python3 hotkey-remap.py
Generated by pi-arcade-setup.
"""
import curses, json, select, struct, subprocess, sys

JS_DEVICE = "/dev/input/js0"
CONFIG_FILE = "$PI_HOME/.controller-hotkeys-buttons.json"

JS_EVENT_BUTTON = 0x01
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

ROLES = [
    ("l3", "L3", "Left stick click"),
    ("r3", "R3", "Right stick click"),
    ("square", "SQUARE", "Brightness UP"),
    ("x", "X / CROSS", "Brightness DOWN"),
    ("triangle", "TRIANGLE", "Volume UP"),
    ("circle", "CIRCLE", "Volume DOWN"),
]

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD = 1, 2, 3, 4, 5


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


def draw_chrome(win, subtitle):
    win.erase()
    h, w = win.getmaxyx()
    title = " CONTROLLER HOTKEY MAPPING "
    safe_addstr(win, 1, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)
    if subtitle:
        safe_addstr(win, 3, cx(win, subtitle), subtitle, curses.A_DIM)
    footer = " ESC  CANCEL "
    safe_addstr(win, h - 2, cx(win, footer), footer, curses.color_pair(COL_HEADER))


def draw_progress(win, step, total):
    dots = " ".join("●" if i < step else "○" for i in range(total))
    safe_addstr(win, 5, cx(win, dots), dots, curses.color_pair(COL_LABEL))
    label = f"STEP {step} OF {total}"
    safe_addstr(win, 6, cx(win, label), label, curses.A_DIM)


def draw_prompt(win, name, desc, status="", status_attr=0):
    h, _ = win.getmaxyx()
    mid = h // 2
    safe_addstr(win, mid - 3, cx(win, "PRESS THE BUTTON FOR"), "PRESS THE BUTTON FOR", curses.A_DIM)
    safe_addstr(win, mid - 1, cx(win, name), name, curses.color_pair(COL_LABEL) | curses.A_BOLD)
    safe_addstr(win, mid, cx(win, desc), desc)
    hint = "(press it twice to confirm)"
    safe_addstr(win, mid + 2, cx(win, hint), hint, curses.color_pair(COL_HINT) | curses.A_DIM)
    if status:
        safe_addstr(win, mid + 4, cx(win, status), status, status_attr | curses.A_BOLD)
    win.refresh()


def wait_for_input(win, js_fd, js_file, any_key_continues=False):
    win.nodelay(True)
    while True:
        r, _, _ = select.select([js_fd, sys.stdin], [], [], 0.05)
        if sys.stdin in r:
            ch = win.getch()
            if ch == 27:
                return ("cancel", None)
            if ch != -1 and any_key_continues:
                return ("continue", None)
        if js_fd in r:
            data = js_file.read(EVENT_SIZE)
            if data and len(data) == EVENT_SIZE:
                _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
                if typ & JS_EVENT_INIT:
                    continue
                if typ == JS_EVENT_BUTTON and value == 1:
                    return ("continue", None) if any_key_continues else ("button", number)


def capture_role(win, js_fd, js_file, step, total, name, desc):
    while True:
        draw_chrome(win, ""); draw_progress(win, step, total); draw_prompt(win, name, desc)
        kind, val = wait_for_input(win, js_fd, js_file)
        if kind == "cancel":
            return None
        draw_chrome(win, ""); draw_progress(win, step, total)
        draw_prompt(win, name, desc, f"GOT BUTTON {val} - PRESS AGAIN TO CONFIRM", curses.color_pair(COL_HINT))
        kind2, val2 = wait_for_input(win, js_fd, js_file)
        if kind2 == "cancel":
            return None
        if val == val2:
            draw_chrome(win, ""); draw_progress(win, step, total)
            draw_prompt(win, name, desc, f"CONFIRMED: BUTTON {val}", curses.color_pair(COL_GOOD))
            curses.napms(700)
            return val
        else:
            draw_chrome(win, ""); draw_progress(win, step, total)
            draw_prompt(win, name, desc, "DIDN'T MATCH - TRY AGAIN", curses.color_pair(COL_BAD))
            curses.napms(900)


def show_message(win, lines, wait_key=True, js_fd=None, js_file=None):
    win.erase()
    h, w = win.getmaxyx()
    top = h // 2 - len(lines) // 2
    for i, (text, attr) in enumerate(lines):
        safe_addstr(win, top + i, cx(win, text), text, attr)
    win.refresh()
    if wait_key:
        if js_fd is not None:
            wait_for_input(win, js_fd, js_file, any_key_continues=True)
        else:
            win.nodelay(False)
            win.getch()


def run(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(COL_HEADER, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(COL_HINT, curses.COLOR_YELLOW, -1)
    curses.init_pair(COL_GOOD, curses.COLOR_GREEN, -1)
    curses.init_pair(COL_BAD, curses.COLOR_RED, -1)

    try:
        js_file = open(JS_DEVICE, "rb")
    except FileNotFoundError:
        show_message(stdscr, [("NO CONTROLLER FOUND", curses.color_pair(COL_BAD) | curses.A_BOLD),
                               (f"Could not open {JS_DEVICE}", curses.A_DIM)], wait_key=False)
        curses.napms(1500)
        return None

    js_fd = js_file.fileno()
    draw_chrome(stdscr, "")
    show_message(stdscr, [
        ("CONTROLLER HOTKEY MAPPING", curses.color_pair(COL_HEADER) | curses.A_BOLD), ("", 0),
        ("You'll be asked to press each button twice, one at a time.", 0),
        ("Press any button to begin, or ESC to cancel.", curses.A_DIM),
    ], js_fd=js_fd, js_file=js_file)

    try:
        mapping = {}
        total = len(ROLES)
        for i, (key, name, desc) in enumerate(ROLES, start=1):
            val = capture_role(stdscr, js_fd, js_file, i, total, name, desc)
            if val is None:
                show_message(stdscr, [("CANCELLED", curses.color_pair(COL_BAD) | curses.A_BOLD),
                                       ("No changes were saved.", curses.A_DIM)], wait_key=False)
                curses.napms(1200)
                return None
            mapping[key] = val

        lines = [("MAPPING COMPLETE", curses.color_pair(COL_GOOD) | curses.A_BOLD), ("", 0)]
        for key, name, desc in ROLES:
            lines.append((f"{name:<12} ({desc}):  button {mapping[key]}", 0))
        lines.append(("", 0))
        lines.append(("Press any button or key to continue...", curses.A_DIM))
        show_message(stdscr, lines, js_fd=js_fd, js_file=js_file)
        return mapping
    finally:
        js_file.close()


def main():
    mapping = curses.wrapper(run)
    if not mapping:
        return
    with open(CONFIG_FILE, "w") as f:
        json.dump(mapping, f, indent=2)
    subprocess.run(["sudo", "systemctl", "restart", "controller-hotkeys.service"], check=False)
    print()
    print("=" * 50)
    print(" New hotkey mapping saved and applied:")
    for key, name, desc in ROLES:
        print(f"   {name:<12} ({desc}):  button {mapping[key]}")
    print("=" * 50)


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PI_HOME/scripts/hotkey-remap.py"

    touch "$PI_HOME/RetroPie/retropiemenu/hotkeyconfig.rp"

    local menu_script="$PI_HOME/RetroPie-Setup/scriptmodules/supplementary/retropiemenu.sh"
    if [ -f "$menu_script" ] && ! grep -q "hotkeyconfig.rp)" "$menu_script"; then
        sudo cp "$menu_script" "${menu_script}.bak.$(date +%s)"
        sudo python3 - "$menu_script" "$PI_HOME" <<'PYEOF'
import sys
path, pi_home = sys.argv[1], sys.argv[2]
text = open(path).read()
anchor = "filemanager.rp)"
idx = text.find(anchor)
if idx == -1:
    print("[hotkeyconfig] anchor 'filemanager.rp)' not found in retropiemenu.sh; skipping menu wiring")
    sys.exit(0)
# Insert a new case immediately after the filemanager.rp) case's closing
# ";;", preserving indentation (matches the reference build exactly).
case_end = text.find(";;", idx)
if case_end == -1:
    print("[hotkeyconfig] could not find end of filemanager.rp) case; skipping menu wiring")
    sys.exit(0)
insert_point = text.find("\n", case_end) + 1
line_start = text.rfind("\n", 0, idx) + 1
indent = text[line_start:idx]
insert_block = f"{indent}hotkeyconfig.rp)\n{indent}    python3 {pi_home}/scripts/hotkey-remap.py\n{indent}    ;;\n"
new_text = text[:insert_point] + insert_block + text[insert_point:]
open(path, "w").write(new_text)
print("[hotkeyconfig] wired into retropiemenu.sh")
PYEOF
    fi
    return 0
}

phase_led_strip_setup() {
    if [ "$ENABLE_LED_STRIP" != "true" ]; then
        log "ENABLE_LED_STRIP=false, skipping"
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


def poll_action(stdscr, js_file, axis_state, timeout=0.08):
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

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        return "confirm"
                    if number == BTN_BACK:
                        return "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if sys.stdin in ready:
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
            return "confirm"
        if ch in (27, ord("q"), ord("Q")):
            return "back"
    return None


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

    cfg = load_config()
    sel = 0
    preset_idx = 0
    save_config(cfg)

    try:
        while True:
            draw(stdscr, cfg, sel, preset_idx, js_file is not None)
            action = poll_action(stdscr, js_file, axis_state)
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
    # Turns the Pi into an always-on A2DP sink via PipeWire/WirePlumber's
    # native Bluetooth module (libspa-0.2-bluetooth) - this OS image already
    # runs PipeWire by default (see phase_audio_output_setup), so this is
    # the native path rather than pulling in bluealsa (not packaged for
    # this Debian release) or a whole separate PulseAudio stack. bt-agent
    # (bluez-tools) is a headless "NoInputNoOutput" pairing agent so phones
    # (and controllers, for the Bluetooth pairing tool) can pair without
    # any PIN prompt.
    sudo apt-get install -y bluez-tools python3-dbus python3-gi libspa-0.2-bluetooth \
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
    "\n# pi-arcade-setup: always-discoverable/pairable speaker, identifies as\n"
    "# an Audio/Video Loudspeaker (Rendering + Audio service bits, per the\n"
    "# Bluetooth CoD spec) so it shows up sensibly in phone BT device lists.\n"
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

    # Persist the pi user's PipeWire/WirePlumber session across reboots so
    # the A2DP sink is always up, independent of whether a console/graphical
    # session is active.
    sudo loginctl enable-linger "$PI_USER" || log_warn "could not enable linger for $PI_USER"

    local uid
    uid="$(id -u "$PI_USER")"
    sudo -u "$PI_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null \
        || log_warn "could not restart pipewire/wireplumber user services; Bluetooth audio will apply on next login"

    mkdir -p "$PI_HOME/scripts"
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
POLL_INTERVAL = 1.0

BLUEZ_SERVICE = "org.bluez"
DEVICE_IFACE = "org.bluez.Device1"
PLAYER_IFACE = "org.bluez.MediaPlayer1"
PROPS_IFACE = "org.freedesktop.DBus.Properties"


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
        return None, None, None

    player_path, player_props = None, None
    for path, ifaces in objects.items():
        if path.startswith(device_path) and PLAYER_IFACE in ifaces:
            player_path, player_props = path, ifaces[PLAYER_IFACE]
            break

    return device_props, player_path, player_props


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
    bus = dbus.SystemBus()
    last_seq = None
    while True:
        objects = get_managed_objects(bus)
        auto_trust(bus, objects)
        device_props, player_path, player_props = find_connected_device_and_player(objects)
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

    sudo tee /etc/systemd/system/bt-agent.service >/dev/null <<EOF
[Unit]
Description=Headless Bluetooth pairing agent (auto-accept, NoInputNoOutput)
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/bt-agent -c NoInputNoOutput
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    # Clean up the old always-discoverable service from earlier versions of
    # this script, if present (upgrade path) - superseded by bt-power-on.service.
    if [ -f /etc/systemd/system/bt-discoverable.service ]; then
        sudo systemctl disable --now bt-discoverable.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/bt-discoverable.service
    fi

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
ExecStart=/usr/bin/bash -c 'bluetoothctl power on; bluetoothctl discoverable off; bluetoothctl pairable off'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo tee /etc/systemd/system/bt-nowplaying-daemon.service >/dev/null <<EOF
[Unit]
Description=Bluetooth AVRCP now-playing status/control daemon
After=bluetooth.service dbus.service
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


def poll_action(stdscr, js_file, axis_state, timeout=0.15):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        return "confirm"
                    if number == BTN_BACK:
                        return "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_UP:
            return "up"
        if ch == curses.KEY_DOWN:
            return "down"
        if ch in (10, 13, ord(" ")):
            return "confirm"
        if ch in (27, ord("q"), ord("Q")):
            return "back"
    return None


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
            action = poll_action(stdscr, js_file, axis_state)
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
PipeWire, so this tool is only a display+remote (closing it does not stop
playback). Also adjusts the Pi's own output volume.

The Pi only shows up as a connectable Bluetooth device to a NEW phone
while this screen is open (discoverable/pairable are switched on when it
starts and off when it exits) - a phone that's already paired can still
reconnect and stream at any time.

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

    title_bar = f"🔊  {SPEAKER_NAME}  🔊"
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
        hint = f'Pair a phone to "{SPEAKER_NAME}" to stream music here'
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
            sub = "(play something on your phone)"
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
    # `finally` block below, however this loop exits.
    set_discoverable(True)

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


def poll_action(stdscr, js_file, axis_state, timeout=0.1):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        return "confirm"
                    if number == BTN_BACK:
                        return "back"
                elif typ == JS_EVENT_AXIS and number in (0, 1):
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(number, False)
                    axis_state[number] = past
                    if past and not was_past:
                        if number == 0:
                            return "right" if value > 0 else "left"
                        else:
                            return "down" if value > 0 else "up"

    if sys.stdin in ready:
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
            return "confirm"
        if ch in (27, ord("q"), ord("Q")):
            return "back"
    return None


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
            action = poll_action(stdscr, js_file, axis_state)
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


def poll_action(stdscr, js_file, axis_state, timeout=0.15):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init:
                if typ == JS_EVENT_BUTTON and value == 1:
                    if number == BTN_CONFIRM:
                        return "confirm"
                    if number == BTN_BACK:
                        return "back"
                elif typ == JS_EVENT_AXIS and number == 0:
                    past = abs(value) > AXIS_THRESHOLD
                    was_past = axis_state.get(0, False)
                    axis_state[0] = past
                    if past and not was_past:
                        return "right" if value > 0 else "left"

    if sys.stdin in ready:
        ch = stdscr.getch()
        if ch == curses.KEY_LEFT:
            return "left"
        if ch == curses.KEY_RIGHT:
            return "right"
        if ch in (10, 13, ord(" ")):
            return "confirm"
        if ch in (27, ord("q"), ord("Q")):
            return "back"
    return None


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
    yes_selected = True

    result = False
    try:
        while True:
            draw(stdscr, yes_selected, js_file is not None)
            action = poll_action(stdscr, js_file, axis_state)
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
FTP server on/off switch for pi-arcade-setup. Run from the RetroPie menu
("FTP settings") or directly:
    python3 ftp-settings.py
Toggles the proftpd service pi-arcade-setup installs (enable+start /
disable+stop), so file transfer only runs when you actually want it.

Works with the controller as well as the keyboard: X/Cross toggles,
Circle/B exits - same button roles as the rest of the RetroPie menu.
"""
import curses
import select
import struct
import subprocess
import sys

JS_DEVICE = "/dev/input/js0"
JS_EVENT_BUTTON = 0x01
JS_EVENT_INIT = 0x80
EVENT_FORMAT = "IhBB"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
BTN_CONFIRM = $BTN_X       # X / Cross / A - same role as the rest of the RetroPie menu
BTN_BACK = $BTN_CIRCLE     # Circle / B - same role as the rest of the RetroPie menu

SERVICE = "proftpd"

COL_HEADER, COL_LABEL, COL_HINT, COL_GOOD, COL_BAD = 1, 2, 3, 4, 5


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


def is_enabled():
    try:
        r = subprocess.run(["systemctl", "is-enabled", SERVICE], capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "enabled"
    except Exception:
        return False


def is_active():
    try:
        r = subprocess.run(["systemctl", "is-active", SERVICE], capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "active"
    except Exception:
        return False


def set_enabled(enable):
    if enable:
        subprocess.run(["sudo", "systemctl", "enable", "--now", SERVICE], capture_output=True, timeout=10)
    else:
        subprocess.run(["sudo", "systemctl", "disable", "--now", SERVICE], capture_output=True, timeout=10)


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


def poll_action(stdscr, js_file, timeout=0.15):
    fds = [sys.stdin]
    if js_file is not None:
        fds.append(js_file)
    try:
        ready, _, _ = select.select(fds, [], [], timeout)
    except (OSError, ValueError):
        ready = []

    if js_file is not None and js_file in ready:
        data = js_file.read(EVENT_SIZE)
        if data and len(data) == EVENT_SIZE:
            _t, value, typ, number = struct.unpack(EVENT_FORMAT, data)
            is_init = bool(typ & JS_EVENT_INIT)
            typ &= ~JS_EVENT_INIT
            if not is_init and typ == JS_EVENT_BUTTON and value == 1:
                if number == BTN_CONFIRM:
                    return "confirm"
                if number == BTN_BACK:
                    return "back"

    if sys.stdin in ready:
        ch = stdscr.getch()
        if ch in (10, 13, ord(" ")):
            return "confirm"
        if ch in (27, ord("q"), ord("Q")):
            return "back"
    return None


def draw(win, enabled, active, busy, js_connected):
    win.erase()
    h, w = win.getmaxyx()
    title = " FTP SETTINGS "
    safe_addstr(win, 2, cx(win, title), title, curses.color_pair(COL_HEADER) | curses.A_BOLD)

    status = "ON" if enabled else "OFF"
    attr = curses.color_pair(COL_GOOD) if enabled else curses.color_pair(COL_BAD)
    line = f"FTP server: {status}"
    safe_addstr(win, h // 2 - 2, cx(win, line), line, attr | curses.A_BOLD)

    if busy:
        sub = "Applying..."
    elif enabled and active:
        sub = "Running - connect with any FTP client using the Pi user login."
    elif enabled and not active:
        sub = "Enabled but not running yet."
    else:
        sub = "Disabled."
    safe_addstr(win, h // 2 - 1, cx(win, sub), sub, curses.A_DIM)

    if enabled:
        ip_line = f"ftp://{get_ip()}"
        safe_addstr(win, h // 2 + 1, cx(win, ip_line), ip_line, curses.color_pair(COL_LABEL))

    js_line = "Controller connected" if js_connected else "No controller detected - keyboard only"
    safe_addstr(win, h - 3, cx(win, js_line), js_line, curses.A_DIM)

    footer = "Enter/A/X: toggle on/off   ESC/B/Circle: exit"
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
    stdscr.nodelay(True)
    stdscr.keypad(True)

    js_file = open_joystick()
    enabled = is_enabled()
    active = is_active()

    try:
        while True:
            draw(stdscr, enabled, active, False, js_file is not None)
            action = poll_action(stdscr, js_file)
            if action is None:
                continue
            if action == "back":
                break
            if action == "confirm":
                draw(stdscr, enabled, active, True, js_file is not None)
                set_enabled(not enabled)
                enabled = is_enabled()
                active = is_active()
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
        base_update
        display_setup
        verify_display
        retropie_install
        emulators_install
        retroarch_autoconfig
        video_rotation_setup
        ftp_install
        disk_cleanup
        esde_build_deps
        esde_build
        esde_config
        esde_retroarch_links
        themes_install
        theme_system_art
        autostart_setup
        custom_retropie_system
        splash_setup
        polkit_fix
        controller_hotkeys
        hotkey_remap_tool
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
        finalize
    )

    for phase in "${PHASES[@]}"; do
        run_phase "$phase"
    done

    log "All phases complete."
}

main "$@"
