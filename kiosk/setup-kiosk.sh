#!/usr/bin/env bash
# setup-kiosk.sh — Idempotent Ubuntu 24.04 kiosk setup
# Usage: sudo ./setup-kiosk.sh
#
# What this script does:
#   1. Installs: sway, swaybg, swayidle, chromium, and supporting packages
#   2. Creates a locked-password 'kiosk' user with auto-login via gdm3 (Sway session)
#   3. Deploys a Chromium kiosk service pointing at http://localhost:8080
#   4. Sets up a photo slideshow screensaver (no lock screen — any input wakes back to Chromium)
#   5. Records all changes to /etc/kiosk-deploy.manifest for clean, full reversal
#
# Idempotent: safe to re-run. Already-done steps are skipped.
# Reverse with: sudo ./cleanup-kiosk.sh

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"
KIOSK_URL="http://localhost:8080"
SCREENSAVER_TIMEOUT=600   # seconds before screensaver kicks in (10 min)
SLIDE_INTERVAL=15         # seconds per image in slideshow

MANIFEST="/etc/kiosk-deploy.manifest"
GDM3_CONF="/etc/gdm3/custom.conf"
GDM3_BACKUP="${GDM3_CONF}.kiosk-backup"
SWAY_SESSION="/usr/share/wayland-sessions/sway.desktop"
ACCOUNTS_FILE="/var/lib/AccountsService/users/${KIOSK_USER}"
SUDOERS_FILE="/etc/sudoers.d/kiosk"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn] ${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }
step() { echo -e "\n${BLUE}==> $*${NC}"; }

# ── Manifest helpers ──────────────────────────────────────────────────────────
manifest_add() {   # manifest_add KEY VALUE
    grep -qxF "${1}:${2}" "$MANIFEST" 2>/dev/null || echo "${1}:${2}" >> "$MANIFEST"
}
manifest_has() {   # manifest_has KEY VALUE  →  returns 0/1
    grep -qxF "${1}:${2}" "$MANIFEST" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────
step "Preflight"

if [[ $EUID -ne 0 ]]; then
    err "Run as root:  sudo ./setup-kiosk.sh"
    exit 1
fi

# Verify gdm3 is present (required for auto-login config)
if ! command -v gdm3 &>/dev/null && ! dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    err "gdm3 not found. Install it first:  sudo apt install gdm3"
    exit 1
fi

# Create manifest
if [[ ! -f "$MANIFEST" ]]; then
    cat > "$MANIFEST" <<EOF
# kiosk-deploy manifest — created $(date)
# DO NOT EDIT — used by cleanup-kiosk.sh to reverse this setup precisely.
EOF
    log "Created manifest: $MANIFEST"
else
    log "Manifest already exists — resuming idempotent run"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
step "Installing packages"

apt-get update -qq

PACKAGES=(sway swaybg swayidle dbus-user-session fonts-liberation libpam-systemd policykit-1)

for pkg in "${PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        log "Already installed: $pkg"
    else
        log "Installing $pkg ..."
        apt-get install -y -qq "$pkg"
        manifest_add "INSTALLED_PKG" "$pkg"
        log "Installed: $pkg"
    fi
done

# Chromium — on Ubuntu 24.04 the apt package is a snap wrapper
step "Installing Chromium"
if dpkg -l chromium-browser 2>/dev/null | grep -q '^ii'; then
    log "chromium-browser deb already present"
elif snap list chromium &>/dev/null 2>&1; then
    log "Chromium snap already present"
else
    log "Installing chromium-browser ..."
    # This may install the snap-backed transitional package
    if apt-get install -y -qq chromium-browser 2>/dev/null; then
        manifest_add "INSTALLED_PKG" "chromium-browser"
        log "Installed chromium-browser"
    else
        warn "apt install failed — falling back to snap"
        snap install chromium
        manifest_add "INSTALLED_SNAP" "chromium"
        log "Installed chromium snap"
    fi
fi

# Detect the actual binary (apt wrapper, snap wrapper, or direct path)
CHROMIUM_BIN=""
for candidate in /usr/bin/chromium-browser /usr/bin/chromium /snap/bin/chromium; do
    if [[ -x "$candidate" ]]; then
        CHROMIUM_BIN="$candidate"
        break
    fi
done
# Also try PATH
if [[ -z "$CHROMIUM_BIN" ]]; then
    CHROMIUM_BIN=$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || true)
fi
if [[ -z "$CHROMIUM_BIN" ]]; then
    err "Chromium binary not found after installation. Resolve manually and re-run."
    exit 1
fi
log "Chromium binary: $CHROMIUM_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# 3. KIOSK USER
# ─────────────────────────────────────────────────────────────────────────────
step "Creating kiosk user"

if id "$KIOSK_USER" &>/dev/null; then
    log "User '$KIOSK_USER' already exists — skipping creation"
else
    useradd -m -s /bin/bash "$KIOSK_USER"
    passwd -l "$KIOSK_USER"   # lock: no password login; auto-login only
    log "Created user: $KIOSK_USER (password locked)"
fi

for grp in sudo video audio input render; do
    if getent group "$grp" &>/dev/null; then
        usermod -aG "$grp" "$KIOSK_USER"
    else
        warn "Group '$grp' not found — skipping"
    fi
done
log "Group memberships updated"

# ─────────────────────────────────────────────────────────────────────────────
# 4. SUDOERS
# ─────────────────────────────────────────────────────────────────────────────
step "Sudoers entry"

cat > "$SUDOERS_FILE" <<EOF
# kiosk-deploy: sudo access for the kiosk user (allows maintenance over SSH)
# WARNING: passwordless sudo — acceptable for a dedicated kiosk machine
${KIOSK_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 "$SUDOERS_FILE"
log "Wrote: $SUDOERS_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# 5. WAYLAND SESSION FILE
# ─────────────────────────────────────────────────────────────────────────────
step "Wayland session file"

if [[ -f "$SWAY_SESSION" ]]; then
    log "Sway session file already exists (installed by sway package) — leaving it alone"
else
    mkdir -p "$(dirname "$SWAY_SESSION")"
    cat > "$SWAY_SESSION" <<EOF
[Desktop Entry]
Name=Sway
Comment=An i3-compatible Wayland compositor
Exec=sway
Type=Application
DesktopNames=sway
EOF
    manifest_add "CREATED_SWAY_SESSION" "1"
    log "Created: $SWAY_SESSION"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. ACCOUNTSSERVICE — pin session to Sway
# ─────────────────────────────────────────────────────────────────────────────
step "AccountsService session selector"

mkdir -p "$(dirname "$ACCOUNTS_FILE")"
cat > "$ACCOUNTS_FILE" <<EOF
[User]
Session=sway
SystemAccount=false
EOF
log "Wrote: $ACCOUNTS_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# 7. GDM3 AUTO-LOGIN
# ─────────────────────────────────────────────────────────────────────────────
step "gdm3 auto-login"

# Back up original once (idempotent — won't overwrite an existing backup)
if [[ -f "$GDM3_CONF" ]] && [[ ! -f "$GDM3_BACKUP" ]]; then
    cp "$GDM3_CONF" "$GDM3_BACKUP"
    log "Backed up: $GDM3_CONF → $GDM3_BACKUP"
elif [[ -f "$GDM3_BACKUP" ]]; then
    log "Backup already exists: $GDM3_BACKUP"
fi

# Rewrite the [daemon] section, preserve everything else
python3 - <<PYEOF
import re, os, sys

conf_path = "${GDM3_CONF}"
kiosk_user = "${KIOSK_USER}"

original = ""
if os.path.exists(conf_path):
    with open(conf_path) as f:
        original = f.read()

# Strip the existing [daemon] block (from [daemon] up to next [section] or EOF)
cleaned = re.sub(
    r'^\[daemon\][^\[]*',
    '',
    original,
    flags=re.MULTILINE | re.DOTALL | re.IGNORECASE
).strip()

daemon_block = f"""[daemon]
AutomaticLoginEnable=True
AutomaticLogin={kiosk_user}
WaylandEnable=true
"""

os.makedirs(os.path.dirname(conf_path) or ".", exist_ok=True)
with open(conf_path, "w") as f:
    f.write(daemon_block)
    if cleaned:
        f.write("\n" + cleaned + "\n")

print(f"Wrote {conf_path}")
PYEOF

log "gdm3 auto-login configured → user: $KIOSK_USER, session: sway"

# ─────────────────────────────────────────────────────────────────────────────
# 8. HOME DIRECTORY STRUCTURE
# ─────────────────────────────────────────────────────────────────────────────
step "kiosk home directory structure"

for dir in \
    "${KIOSK_HOME}/.config/sway" \
    "${KIOSK_HOME}/.config/systemd/user" \
    "${KIOSK_HOME}/.local/bin" \
    "${KIOSK_HOME}/screensaver"
do
    mkdir -p "$dir"
done
log "Directories created under $KIOSK_HOME"

# ─────────────────────────────────────────────────────────────────────────────
# 9. SWAY CONFIG
# ─────────────────────────────────────────────────────────────────────────────
step "Sway configuration"

KIOSK_UID=$(id -u "$KIOSK_USER")

cat > "${KIOSK_HOME}/.config/sway/config" <<EOF
# kiosk-deploy: Sway config for the kiosk user
# Managed by setup-kiosk.sh — changes will be overwritten on re-run

# ── Appearance ────────────────────────────────────────────────────────────────
default_border none
default_floating_border none
# Solid black background; Chromium covers it when running
output * bg #000000 solid_color

# ── Input ─────────────────────────────────────────────────────────────────────
# Allow any input device to wake the screensaver (swayidle handles this)
input * tap enabled

# ── Environment import ────────────────────────────────────────────────────────
# Propagate the Wayland display env to the systemd user session and dbus so
# that the Chromium service can find the display.
exec systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR 2>/dev/null || true

# ── Screensaver (no lock screen) ──────────────────────────────────────────────
# After ${SCREENSAVER_TIMEOUT}s idle: switch to empty workspace and show photo slideshow.
# On any input: swayidle fires 'resume' → return to Chromium on workspace 1.
exec swayidle -w \\
    timeout ${SCREENSAVER_TIMEOUT} '${KIOSK_HOME}/.local/bin/screensaver-start.sh' \\
    resume                         '${KIOSK_HOME}/.local/bin/screensaver-stop.sh'

# ── Kiosk application ─────────────────────────────────────────────────────────
# Chromium always lives on workspace 1. kiosk-startup.sh handles env import
# and then starts the Chromium systemd user service.
workspace 1
exec ${KIOSK_HOME}/.local/bin/kiosk-startup.sh

# ── Status bar ────────────────────────────────────────────────────────────────
bar {
    mode invisible
}
EOF

log "Wrote: ${KIOSK_HOME}/.config/sway/config"

# ─────────────────────────────────────────────────────────────────────────────
# 10. KIOSK STARTUP SCRIPT
# ─────────────────────────────────────────────────────────────────────────────
step "kiosk-startup.sh"

cat > "${KIOSK_HOME}/.local/bin/kiosk-startup.sh" <<'SCRIPT'
#!/usr/bin/env bash
# kiosk-deploy: kiosk-startup.sh
# Run by Sway on session start. Imports the Wayland environment into the
# systemd user session, then starts the Chromium kiosk service.

# Push Wayland display vars into the running systemd user instance
systemctl --user import-environment \
    WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS \
    2>/dev/null || true

dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR \
    2>/dev/null || true

# Short wait for the compositor + dbus to finish initialising
sleep 2

# Start (or restart) the Chromium kiosk service
systemctl --user start chromium-kiosk.service
SCRIPT

chmod +x "${KIOSK_HOME}/.local/bin/kiosk-startup.sh"
log "Wrote: ${KIOSK_HOME}/.local/bin/kiosk-startup.sh"

# ─────────────────────────────────────────────────────────────────────────────
# 11. CHROMIUM SYSTEMD USER SERVICE
# ─────────────────────────────────────────────────────────────────────────────
step "Chromium systemd user service"

cat > "${KIOSK_HOME}/.config/systemd/user/chromium-kiosk.service" <<EOF
# kiosk-deploy: Chromium kiosk browser service
# Started by kiosk-startup.sh from inside the Sway session.

[Unit]
Description=Chromium Kiosk Browser
# Restart indefinitely — a kiosk should always be showing the app
StartLimitIntervalSec=0

[Service]
ExecStart=${CHROMIUM_BIN} \\
    --kiosk \\
    --no-sandbox \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --disable-translate \\
    --no-first-run \\
    --disable-pinch \\
    --overscroll-history-navigation=0 \\
    --disable-features=TranslateUI \\
    --check-for-update-interval=31536000 \\
    ${KIOSK_URL}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

log "Wrote: ${KIOSK_HOME}/.config/systemd/user/chromium-kiosk.service"
log "Note: service is started at login by kiosk-startup.sh (not via systemd enable)"

# ─────────────────────────────────────────────────────────────────────────────
# 12. SCREENSAVER SCRIPTS
# ─────────────────────────────────────────────────────────────────────────────
step "Screensaver scripts"

# ── screensaver-start.sh ──────────────────────────────────────────────────────
cat > "${KIOSK_HOME}/.local/bin/screensaver-start.sh" <<'SCRIPT'
#!/usr/bin/env bash
# kiosk-deploy: screensaver-start.sh
# Called by swayidle after the idle timeout expires.
# Switches to an empty workspace so the background (slideshow) is visible.
# Chromium keeps running on workspace 1 — untouched.

export SWAYSOCK="${SWAYSOCK:-$(ls /run/user/$(id -u)/sway-ipc.*.sock 2>/dev/null | head -1)}"

# Switch to an empty workspace — Chromium is still alive on workspace 1
swaymsg 'workspace 10' 2>/dev/null || true

# Start the photo slideshow and record its PID for clean teardown
/home/kiosk/.local/bin/slideshow.sh &
echo $! > /tmp/kiosk-slideshow.pid
SCRIPT

# ── screensaver-stop.sh ───────────────────────────────────────────────────────
cat > "${KIOSK_HOME}/.local/bin/screensaver-stop.sh" <<'SCRIPT'
#!/usr/bin/env bash
# kiosk-deploy: screensaver-stop.sh
# Called by swayidle on any user input (mouse, keyboard, touch).
# Kills the slideshow and returns to Chromium on workspace 1.

export SWAYSOCK="${SWAYSOCK:-$(ls /run/user/$(id -u)/sway-ipc.*.sock 2>/dev/null | head -1)}"

# Stop the slideshow cleanly using its saved PID
if [[ -f /tmp/kiosk-slideshow.pid ]]; then
    pid=$(< /tmp/kiosk-slideshow.pid)
    kill "$pid" 2>/dev/null || true
    rm -f /tmp/kiosk-slideshow.pid
fi

# Kill any swaybg instances left over from the slideshow
pkill -u "$(whoami)" -x swaybg 2>/dev/null || true

# Restore solid black background (Chromium will cover it immediately)
swaybg -o '*' -c '#000000' &

# Return to Chromium
swaymsg 'workspace 1' 2>/dev/null || true
SCRIPT

# ── slideshow.sh ──────────────────────────────────────────────────────────────
cat > "${KIOSK_HOME}/.local/bin/slideshow.sh" <<SCRIPT
#!/usr/bin/env bash
# kiosk-deploy: slideshow.sh
# Cycles randomly through images in ~/screensaver using swaybg.
# Killed by screensaver-stop.sh via the PID saved in /tmp/kiosk-slideshow.pid.

PHOTO_DIR="\${HOME}/screensaver"
INTERVAL=${SLIDE_INTERVAL}

# Clean up child swaybg on exit (SIGTERM from screensaver-stop.sh)
trap 'kill "\${SWAYBG_PID}" 2>/dev/null; exit 0' SIGTERM SIGINT

while true; do
    # Build shuffled image list each cycle for variety
    mapfile -t imgs < <(find "\$PHOTO_DIR" -maxdepth 1 -type f \\
        \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) \\
        2>/dev/null | shuf)

    if [[ \${#imgs[@]} -eq 0 ]]; then
        # No photos yet — show solid black and wait
        sleep "\$INTERVAL"
        continue
    fi

    for img in "\${imgs[@]}"; do
        swaybg -o '*' -i "\$img" -m fill &
        SWAYBG_PID=\$!
        sleep "\$INTERVAL"
        kill "\$SWAYBG_PID" 2>/dev/null
        wait "\$SWAYBG_PID" 2>/dev/null
    done
done
SCRIPT

chmod +x \
    "${KIOSK_HOME}/.local/bin/screensaver-start.sh" \
    "${KIOSK_HOME}/.local/bin/screensaver-stop.sh" \
    "${KIOSK_HOME}/.local/bin/slideshow.sh"

log "Wrote screensaver scripts"

# ─────────────────────────────────────────────────────────────────────────────
# 13. ENABLE LINGER
# ─────────────────────────────────────────────────────────────────────────────
step "Enable linger"

loginctl enable-linger "$KIOSK_USER"
log "Linger enabled for $KIOSK_USER (user services persist across login)"

# ─────────────────────────────────────────────────────────────────────────────
# 14. OWNERSHIP + README
# ─────────────────────────────────────────────────────────────────────────────
step "File ownership and screensaver README"

cat > "${KIOSK_HOME}/screensaver/README.txt" <<EOF
Kiosk Screensaver Photos
========================
Drop .jpg, .jpeg, .png, or .webp images into this directory.

The slideshow picks images in random order and advances every ${SLIDE_INTERVAL} seconds.
The screensaver activates after $(( SCREENSAVER_TIMEOUT / 60 )) minutes of idle.
Any keyboard or mouse activity instantly returns to the Chromium kiosk app.

No screen lock is used — this is a display-only screensaver.
EOF

# Ensure kiosk owns everything in their home
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}"
log "Ownership set: ${KIOSK_HOME} → ${KIOSK_USER}:${KIOSK_USER}"

# ─────────────────────────────────────────────────────────────────────────────
# 15. SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Kiosk setup complete ✓               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo
echo -e "  User:               ${KIOSK_USER}  (auto-login via gdm3)"
echo -e "  Session:            Sway (Wayland)"
echo -e "  Chromium URL:       ${KIOSK_URL}"
echo -e "  Chromium binary:    ${CHROMIUM_BIN}"
echo -e "  Screensaver:        ${SCREENSAVER_TIMEOUT}s idle → photo slideshow (no lock)"
echo -e "  Photo directory:    ${KIOSK_HOME}/screensaver/"
echo -e "  Manifest:           ${MANIFEST}"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Copy screensaver photos to:  ${KIOSK_HOME}/screensaver/"
echo -e "  2. Reboot to activate:          sudo reboot"
echo -e "  3. To remove everything later:  sudo ./cleanup-kiosk.sh"
echo
