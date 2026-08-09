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
SPLASH_TRANSFORM_TYPE="${SPLASH_TRANSFORM_TYPE:-90}"    # VLC --transform-type, only used if ENABLE_DSI_DISPLAY
SPLASH_VIDEO_URL="${SPLASH_VIDEO_URL:-}"                # optional custom splash .mp4 to download
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

# --- Controller hotkeys (brightness/volume) ------------------------------
# Safe to leave on for generic hardware: the daemon auto-detects the
# backlight path, no-ops gracefully if no controller/backlight is present,
# and the button numbers below can be re-captured at any time from the
# in-frontend "Hotkey Config" tool this script installs (see README).
ENABLE_CONTROLLER_HOTKEYS="${ENABLE_CONTROLLER_HOTKEYS:-true}"
ALSA_CARD_INDEX="${ALSA_CARD_INDEX:-0}"
BTN_L3="${BTN_L3:-9}"
BTN_R3="${BTN_R3:-10}"
BTN_SQUARE="${BTN_SQUARE:-2}"
BTN_X="${BTN_X:-0}"
BTN_CIRCLE="${BTN_CIRCLE:-1}"
BTN_TRIANGLE="${BTN_TRIANGLE:-3}"
HOTKEY_STEP="${HOTKEY_STEP:-5}"

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
SPLASH_TRANSFORM_TYPE=$SPLASH_TRANSFORM_TYPE
SPLASH_VIDEO_URL=$SPLASH_VIDEO_URL
DO_RPI_FIRMWARE_UPDATE=$DO_RPI_FIRMWARE_UPDATE
EMULATOR_CORES=$EMULATOR_CORES
ESDE_BRANCH=$ESDE_BRANCH
APPLY_ESDE_QUITMENU_PATCH=$APPLY_ESDE_QUITMENU_PATCH
INSTALL_THEMES=$INSTALL_THEMES
ESDE_THEME_NAME=$ESDE_THEME_NAME
INITIAL_FRONTEND=$INITIAL_FRONTEND
ENABLE_CONTROLLER_HOTKEYS=$ENABLE_CONTROLLER_HOTKEYS
ALSA_CARD_INDEX=$ALSA_CARD_INDEX
BTN_L3=$BTN_L3
BTN_R3=$BTN_R3
BTN_SQUARE=$BTN_SQUARE
BTN_X=$BTN_X
BTN_CIRCLE=$BTN_CIRCLE
BTN_TRIANGLE=$BTN_TRIANGLE
HOTKEY_STEP=$HOTKEY_STEP
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
    sudo raspi-config nonint do_change_locale "$LOCALE" 2>/dev/null || {
        sudo sed -i "s/^# *\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen 2>/dev/null || true
        sudo locale-gen || true
        sudo update-locale LANG="$LOCALE" || true
    }
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

    # basic_install fetches dozens of packages/binary assets over the network
    # across a run that can take well over an hour. Blindly retrying the
    # *whole* basic_install on any failure (the previous fix here) turned
    # out not to help in practice: three consecutive real runs all failed
    # on the exact same late-stage fetch (retroarch's cosmetic splashscreen
    # asset pack, retroarch-minimal-assets.tar.gz) after ~80 minutes each
    # time, burning ~4 hours total to end up exactly as stuck as a single
    # attempt would have - EmulationStation, RetroArch and every emulator
    # core had already installed fine every time; only that one trailing
    # cosmetic package kept failing.
    #
    # So: run basic_install once. If it fails but the essentials
    # (EmulationStation + the RetroArch binary) are already on disk, the
    # failure is almost certainly that same late, non-critical package -
    # retry just that specific package directly (seconds, not another
    # ~80-minute rebuild) and don't let it block the rest of setup if it
    # keeps failing, since it has no effect on whether the cabinet actually
    # works. Only fall back to retrying the full basic_install (as before,
    # up to 3 attempts total) if the essentials themselves are missing,
    # i.e. this is a real failure rather than a cosmetic-asset hiccup.
    local es_bin="/opt/retropie/supplementary/emulationstation/emulationstation"
    local ra_bin="/opt/retropie/emulators/retroarch/bin/retroarch"

    if ! sudo ./retropie_packages.sh setup basic_install; then
        if [ -x "$es_bin" ] && [ -x "$ra_bin" ]; then
            log_warn "basic_install failed but EmulationStation and RetroArch are already installed - likely just the cosmetic splashscreen asset pack. Retrying that package directly instead of the full basic_install."
            local attempt splash_ok=false
            for attempt in 1 2 3; do
                if sudo ./retropie_packages.sh splashscreen; then
                    splash_ok=true
                    break
                fi
                log_warn "splashscreen retry $attempt/3 failed, retrying in 15s"
                sleep 15
            done
            [ "$splash_ok" = true ] || log_warn "splashscreen install still failing after retries - continuing without it since it's cosmetic only and won't affect the arcade cabinet's operation."
        else
            log_warn "basic_install failed and EmulationStation/RetroArch are not yet installed - this is a real failure, not a cosmetic-asset hiccup. Retrying the full basic_install."
            local attempt
            for attempt in 2 3; do
                sleep 30
                if sudo ./retropie_packages.sh setup basic_install; then
                    break
                fi
                if [ "$attempt" -eq 3 ]; then
                    die "RetroPie basic_install failed after $attempt attempts"
                fi
                log_warn "RetroPie basic_install failed (attempt $attempt/3) - retrying in 30s"
            done
        fi
    fi

    [ -x "$es_bin" ] || command -v emulationstation >/dev/null 2>&1 || log_warn "emulationstation binary not found where expected after basic_install"
    return 0
}

phase_emulators_install() {
    cd "$PI_HOME/RetroPie-Setup" || die "RetroPie-Setup missing"
    log "Installing MAME (lr-mame)"
    sudo ./retropie_packages.sh lr-mame _binary_ || die "lr-mame install failed"

    IFS=',' read -ra cores <<< "$EMULATOR_CORES"
    for core in "${cores[@]}"; do
        [ -z "$core" ] && continue
        log "Installing emulator core: $core"
        if ! sudo ./retropie_packages.sh "$core" _binary_; then
            log_warn "$core failed to install/build (this is a known flaky step for some cores, e.g. mupen64plus/N64 upstream) - continuing without it"
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
    for name in "${!theme_repos[@]}"; do
        if [ ! -d "$name" ]; then
            git clone --depth=1 "${theme_repos[$name]}" "$name" || log_warn "Failed to clone theme $name"
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
		<path>./audiosettings.rp</path>
		<name>Audio</name>
		<desc>Configure audio settings. Choose default of auto, 3.5mm jack, or HDMI. Mixer controls, and apply default settings.</desc>
		<image>$icon_dir/audiosettings.png</image>
	</game>
	<game>
		<path>./bluetooth.rp</path>
		<name>Bluetooth</name>
		<desc>Register and connect to Bluetooth devices. Unregister and remove devices, and display registered and connected devices.</desc>
		<image>$icon_dir/bluetooth.png</image>
	</game>
	<game>
		<path>./configedit.rp</path>
		<name>Configuration Editor</name>
		<desc>Change common RetroArch options, and manually edit RetroArch configs, global configs, and non-RetroArch configs.</desc>
		<image>$icon_dir/configedit.png</image>
	</game>
	<game>
		<path>./esthemes.rp</path>
		<name>ES Themes</name>
		<desc>Install, uninstall, or update EmulationStation themes.</desc>
		<image>$icon_dir/esthemes.png</image>
	</game>
	<game>
		<path>./filemanager.rp</path>
		<name>File Manager</name>
		<desc>Basic ASCII file manager for Linux allowing you to browse, copy, delete, and move files.</desc>
		<image>$icon_dir/filemanager.png</image>
	</game>
	<game>
		<path>./raspiconfig.rp</path>
		<name>Raspi-Config</name>
		<desc>Change user password, boot options, internationalization, camera, overclock, overscan, memory split, SSH and more.</desc>
		<image>$icon_dir/raspiconfig.png</image>
	</game>
	<game>
		<path>./retroarch.rp</path>
		<name>Retroarch</name>
		<desc>Launches the RetroArch GUI so you can change RetroArch options.</desc>
		<image>$icon_dir/retroarch.png</image>
	</game>
	<game>
		<path>./retronetplay.rp</path>
		<name>RetroArch Net Play</name>
		<desc>Set up RetroArch Netplay options, choose host or client, port, host IP, delay frames, and your nickname.</desc>
		<image>$icon_dir/retronetplay.png</image>
	</game>
	<game>
		<path>./rpsetup.rp</path>
		<name>RetroPie Setup</name>
		<desc>Install RetroPie from binary or source, install experimental packages, additional drivers, edit Samba shares, custom scraper, and more.</desc>
		<image>$icon_dir/rpsetup.png</image>
	</game>
	<game>
		<path>./runcommand.rp</path>
		<name>Run Command Configuration</name>
		<desc>Change what appears on the runcommand screen.</desc>
		<image>$icon_dir/runcommand.png</image>
	</game>
	<game>
		<path>./showip.rp</path>
		<name>Show IP</name>
		<desc>Displays your current IP address and other network information.</desc>
		<image>$icon_dir/showip.png</image>
	</game>
	<game>
		<path>./splashscreen.rp</path>
		<name>Splash Screens</name>
		<desc>Enable or disable the splashscreen on RetroPie boot.</desc>
		<image>$icon_dir/splashscreen.png</image>
	</game>
	<game>
		<path>./wifi.rp</path>
		<name>WiFi</name>
		<desc>Connect to or disconnect from a WiFi network and configure WiFi settings.</desc>
		<image>$icon_dir/wifi.png</image>
	</game>
$( [ "$ENABLE_CONTROLLER_HOTKEYS" = "true" ] && cat <<HOTKEY
	<game>
		<path>./hotkeyconfig.rp</path>
		<name>Hotkey Config</name>
		<desc>Map the controller buttons used for the L3+R3 brightness and volume hotkeys. Press each button twice to confirm.</desc>
		<image>$icon_dir/configedit.png</image>
	</game>
HOTKEY
)
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
            echo "$dest" | sudo tee /etc/splashscreen.list >/dev/null
            log "Custom splash video installed from $SPLASH_VIDEO_URL"
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
        finalize
    )

    for phase in "${PHASES[@]}"; do
        run_phase "$phase"
    done

    log "All phases complete."
}

main "$@"
