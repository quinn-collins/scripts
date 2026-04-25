#!/usr/bin/env bash
# cleanup-kiosk.sh — Full reversal of setup-kiosk.sh
# Usage: sudo ./cleanup-kiosk.sh
#
# What this script does:
#   1. Kills all kiosk user processes and disables auto-login
#   2. Removes the kiosk user and their entire home directory
#   3. Restores gdm3 config from the pre-setup backup
#   4. Removes only the packages that setup-kiosk.sh installed
#      (pre-existing packages are left untouched)
#   5. Removes all other files created by setup-kiosk.sh
#
# Idempotent: safe to re-run. Already-cleaned steps are skipped gracefully.

set -euo pipefail

KIOSK_USER="kiosk"
MANIFEST="/etc/kiosk-deploy.manifest"
GDM3_CONF="/etc/gdm3/custom.conf"
GDM3_BACKUP="${GDM3_CONF}.kiosk-backup"
SWAY_SESSION="/usr/share/wayland-sessions/sway.desktop"
ACCOUNTS_FILE="/var/lib/AccountsService/users/${KIOSK_USER}"
SUDOERS_FILE="/etc/sudoers.d/kiosk"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[cleanup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]   ${NC} $*"; }
step() { echo -e "\n${BLUE}==> $*${NC}"; }

manifest_has() {
    [[ -f "$MANIFEST" ]] && grep -qxF "${1}:${2}" "$MANIFEST" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────
step "Preflight"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[error]${NC} Run as root:  sudo ./cleanup-kiosk.sh" >&2
    exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
    warn "Manifest not found at $MANIFEST"
    warn "Proceeding anyway — will clean up known kiosk files."
fi

echo
echo -e "${YELLOW}This will permanently remove the '$KIOSK_USER' user and all their data.${NC}"
read -r -p "Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. KILL KIOSK PROCESSES
# ─────────────────────────────────────────────────────────────────────────────
step "Stopping kiosk processes"

if id "$KIOSK_USER" &>/dev/null; then
    # Gracefully terminate the entire user session (Sway, Chromium, etc.)
    loginctl terminate-user "$KIOSK_USER" 2>/dev/null || true
    sleep 2
    # Force-kill anything still running as kiosk
    pkill -u "$KIOSK_USER" 2>/dev/null || true
    sleep 1
    log "Kiosk processes stopped"
else
    log "User '$KIOSK_USER' not found — nothing to kill"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. DISABLE LINGER
# ─────────────────────────────────────────────────────────────────────────────
step "Disabling linger"

if id "$KIOSK_USER" &>/dev/null; then
    loginctl disable-linger "$KIOSK_USER" 2>/dev/null || true
    log "Linger disabled for $KIOSK_USER"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. REMOVE KIOSK USER + HOME
# ─────────────────────────────────────────────────────────────────────────────
step "Removing kiosk user and home directory"

if id "$KIOSK_USER" &>/dev/null; then
    userdel -r "$KIOSK_USER" 2>/dev/null || true
    log "Removed user '$KIOSK_USER' and /home/${KIOSK_USER}"
else
    log "User '$KIOSK_USER' already removed"
fi

# Belt-and-suspenders: remove home if userdel left it behind
if [[ -d "/home/${KIOSK_USER}" ]]; then
    rm -rf "/home/${KIOSK_USER}"
    log "Removed leftover /home/${KIOSK_USER}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. SUDOERS
# ─────────────────────────────────────────────────────────────────────────────
step "Removing sudoers entry"

if [[ -f "$SUDOERS_FILE" ]]; then
    rm -f "$SUDOERS_FILE"
    log "Removed: $SUDOERS_FILE"
else
    log "Sudoers file already gone"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. GDM3 — restore original config
# ─────────────────────────────────────────────────────────────────────────────
step "Restoring gdm3 configuration"

if [[ -f "$GDM3_BACKUP" ]]; then
    cp "$GDM3_BACKUP" "$GDM3_CONF"
    rm -f "$GDM3_BACKUP"
    log "Restored: $GDM3_CONF from backup"
elif [[ -f "$GDM3_CONF" ]]; then
    # No backup found — surgically remove our [daemon] block
    warn "No backup found — removing kiosk [daemon] section from $GDM3_CONF"
    python3 - <<'PYEOF'
import re, sys

conf_path = "/etc/gdm3/custom.conf"
with open(conf_path) as f:
    content = f.read()

# Remove the [daemon] section we wrote
cleaned = re.sub(
    r'^\[daemon\][^\[]*',
    '',
    content,
    flags=re.MULTILINE | re.DOTALL | re.IGNORECASE
).strip()

with open(conf_path, "w") as f:
    if cleaned:
        f.write(cleaned + "\n")
    else:
        # Write a minimal valid placeholder
        f.write("# gdm3 configuration\n")

print(f"Cleaned {conf_path}")
PYEOF
    log "Removed kiosk daemon section from $GDM3_CONF"
else
    log "gdm3 config not found — nothing to restore"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. ACCOUNTSSERVICE
# ─────────────────────────────────────────────────────────────────────────────
step "Removing AccountsService entry"

if [[ -f "$ACCOUNTS_FILE" ]]; then
    rm -f "$ACCOUNTS_FILE"
    log "Removed: $ACCOUNTS_FILE"
else
    log "AccountsService entry already gone"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. SWAY SESSION FILE (only if we created it)
# ─────────────────────────────────────────────────────────────────────────────
step "Wayland session file"

if manifest_has "CREATED_SWAY_SESSION" "1"; then
    if [[ -f "$SWAY_SESSION" ]]; then
        rm -f "$SWAY_SESSION"
        log "Removed: $SWAY_SESSION (setup-kiosk.sh created this)"
    fi
else
    log "Sway session file was pre-existing — leaving it alone"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. PACKAGES (only ones setup-kiosk.sh installed)
# ─────────────────────────────────────────────────────────────────────────────
step "Removing packages installed by setup-kiosk.sh"

# Collect packages and snaps to remove from manifest
PKGS_TO_REMOVE=()
SNAPS_TO_REMOVE=()

if [[ -f "$MANIFEST" ]]; then
    while IFS=: read -r key value; do
        case "$key" in
            INSTALLED_PKG)  PKGS_TO_REMOVE+=("$value") ;;
            INSTALLED_SNAP) SNAPS_TO_REMOVE+=("$value") ;;
        esac
    done < <(grep -E '^INSTALLED_(PKG|SNAP):' "$MANIFEST" || true)
fi

if [[ ${#PKGS_TO_REMOVE[@]} -gt 0 ]]; then
    log "Purging apt packages: ${PKGS_TO_REMOVE[*]}"
    apt-get purge -y -qq "${PKGS_TO_REMOVE[@]}" || true
    apt-get autoremove -y -qq || true
else
    log "No apt packages recorded in manifest — skipping"
fi

if [[ ${#SNAPS_TO_REMOVE[@]} -gt 0 ]]; then
    for snap_name in "${SNAPS_TO_REMOVE[@]}"; do
        log "Removing snap: $snap_name"
        snap remove "$snap_name" 2>/dev/null || true
    done
else
    log "No snaps recorded in manifest — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 10. MANIFEST
# ─────────────────────────────────────────────────────────────────────────────
step "Removing manifest"

if [[ -f "$MANIFEST" ]]; then
    rm -f "$MANIFEST"
    log "Removed: $MANIFEST"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 11. SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Kiosk cleanup complete ✓             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo
echo -e "  Removed user:       ${KIOSK_USER} + /home/${KIOSK_USER}"
echo -e "  gdm3 config:        restored from backup (or cleaned)"
echo -e "  Packages:           purged (only those installed by setup-kiosk.sh)"
echo
echo -e "${YELLOW}Recommend a reboot to complete the reversal:${NC}  sudo reboot"
echo
