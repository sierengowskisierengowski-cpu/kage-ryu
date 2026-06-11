#!/usr/bin/env bash
# =============================================================================
# splash/install-splash.sh — Kage-Ryu Plymouth Boot Splash Installer
# =============================================================================
#
# Prerequisites (Arch Linux):
#   - plymouth         (pacman -S plymouth)
#   - mkinitcpio       (pacman -S mkinitcpio)
#   - grub             (pacman -S grub)   — only needed for GRUB cmdline update
#
# Usage:
#   sudo bash splash/install-splash.sh
#
# What this script does (in order):
#   1. Checks for required tools (plymouth, mkinitcpio)
#   2. Installs the kage-ryu Plymouth theme to /usr/share/plymouth/themes/
#   3. Sets kage-ryu as the default Plymouth theme
#   4. Idempotently adds the 'plymouth' hook to /etc/mkinitcpio.conf
#   5. Regenerates all initramfs images with mkinitcpio -P
#   6. Ensures 'splash quiet' are in GRUB_CMDLINE_LINUX_DEFAULT
#   7. Regenerates grub.cfg (if /boot/grub/grub.cfg exists)
# =============================================================================

set -euo pipefail

SPLASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SPLASH_DIR}/.." && pwd)"

THEME_NAME="kage-ryu"
THEME_DIR="/usr/share/plymouth/themes/${THEME_NAME}"

# ── Colour helpers ────────────────────────────────────────────────────────────
info()  { printf '\e[36m[INFO]\e[0m  %s\n'  "$*"; }
ok()    { printf '\e[32m[ OK ]\e[0m  %s\n'  "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n'  "$*"; }
die()   { printf '\e[31m[FAIL]\e[0m  %s\n'  "$*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)."

# ── Step 1: Dependency checks ─────────────────────────────────────────────────
info "Checking required tools…"
command -v plymouth              &>/dev/null || die "plymouth not found. Install with: pacman -S plymouth"
command -v plymouth-set-default-theme &>/dev/null || die "plymouth-set-default-theme not found. Install with: pacman -S plymouth"
command -v mkinitcpio            &>/dev/null || die "mkinitcpio not found. Install with: pacman -S mkinitcpio"
ok "All required tools present."

# ── Step 2: Install the theme ─────────────────────────────────────────────────
info "Installing Plymouth theme '${THEME_NAME}' to ${THEME_DIR}/…"

LOGO_SRC="${REPO_ROOT}/assets/logo.png"
[[ -f "${LOGO_SRC}" ]] || die "Logo not found: ${LOGO_SRC}"

install -d "${THEME_DIR}"
install -m 644 "${SPLASH_DIR}/kage-ryu.plymouth" "${THEME_DIR}/kage-ryu.plymouth"
install -m 644 "${SPLASH_DIR}/kage-ryu.script"   "${THEME_DIR}/kage-ryu.script"
install -m 644 "${LOGO_SRC}"                      "${THEME_DIR}/logo.png"
ok "Theme files installed to ${THEME_DIR}/."

# ── Step 3: Set default Plymouth theme ───────────────────────────────────────
info "Setting '${THEME_NAME}' as the default Plymouth theme…"
plymouth-set-default-theme "${THEME_NAME}"
ok "Default theme set to '${THEME_NAME}'."

# ── Step 4: Add 'plymouth' hook to /etc/mkinitcpio.conf ──────────────────────
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
info "Updating ${MKINITCPIO_CONF} to include 'plymouth' hook…"

[[ -f "${MKINITCPIO_CONF}" ]] || die "${MKINITCPIO_CONF} not found."

# Back up before editing (idempotent: only overwrite if content differs)
if ! cmp -s "${MKINITCPIO_CONF}" "${MKINITCPIO_CONF}.bak" 2>/dev/null; then
    cp "${MKINITCPIO_CONF}" "${MKINITCPIO_CONF}.bak"
    ok "Backed up ${MKINITCPIO_CONF} → ${MKINITCPIO_CONF}.bak"
fi

if grep -qE '\bplymouth\b' "${MKINITCPIO_CONF}"; then
    ok "'plymouth' hook already present in ${MKINITCPIO_CONF} — skipping."
else
    # Insert 'plymouth' after 'udev' if present, else after 'systemd', else append before closing paren
    if grep -qE '\budev\b' "${MKINITCPIO_CONF}"; then
        sed -i 's/\budev\b/udev plymouth/' "${MKINITCPIO_CONF}"
        ok "Inserted 'plymouth' after 'udev' in HOOKS."
    elif grep -qE '\bsystemd\b' "${MKINITCPIO_CONF}"; then
        sed -i 's/\bsystemd\b/systemd plymouth/' "${MKINITCPIO_CONF}"
        ok "Inserted 'plymouth' after 'systemd' in HOOKS."
    else
        # Fallback: append plymouth before the closing paren of HOOKS=(...)
        sed -i '/^HOOKS=(/s/)$/ plymouth)/' "${MKINITCPIO_CONF}"
        ok "Appended 'plymouth' to HOOKS in ${MKINITCPIO_CONF}."
    fi
fi

# ── Step 5: Regenerate initramfs ──────────────────────────────────────────────
info "Regenerating all initramfs images with mkinitcpio -P…"
mkinitcpio -P
ok "initramfs images regenerated."

# ── Step 6: Update GRUB_CMDLINE_LINUX_DEFAULT ────────────────────────────────
GRUB_DEFAULT="/etc/default/grub"
info "Ensuring 'splash quiet' are in ${GRUB_DEFAULT}…"

if [[ -f "${GRUB_DEFAULT}" ]]; then
    # Back up before editing
    if ! cmp -s "${GRUB_DEFAULT}" "${GRUB_DEFAULT}.bak" 2>/dev/null; then
        cp "${GRUB_DEFAULT}" "${GRUB_DEFAULT}.bak"
        ok "Backed up ${GRUB_DEFAULT} → ${GRUB_DEFAULT}.bak"
    fi

    changed=false

    # Idempotently add 'quiet' if missing
    if ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=.*\bquiet\b' "${GRUB_DEFAULT}"; then
        sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ quiet"/' "${GRUB_DEFAULT}"
        ok "Added 'quiet' to GRUB_CMDLINE_LINUX_DEFAULT."
        changed=true
    fi

    # Idempotently add 'splash' if missing
    if ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=.*\bsplash\b' "${GRUB_DEFAULT}"; then
        sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ splash"/' "${GRUB_DEFAULT}"
        ok "Added 'splash' to GRUB_CMDLINE_LINUX_DEFAULT."
        changed=true
    fi

    if [[ "${changed}" == false ]]; then
        ok "'splash' and 'quiet' already present in ${GRUB_DEFAULT} — skipping."
    fi

    # ── Step 7: Regenerate GRUB config ───────────────────────────────────────
    if [[ -f /boot/grub/grub.cfg ]]; then
        info "Regenerating GRUB config…"
        grub-mkconfig -o /boot/grub/grub.cfg
        ok "GRUB config regenerated at /boot/grub/grub.cfg."
    else
        warn "/boot/grub/grub.cfg not found — skipping grub-mkconfig."
        warn "If you use a different bootloader, add these kernel parameters manually:"
        warn "  splash quiet"
    fi
else
    warn "${GRUB_DEFAULT} not found — skipping GRUB update."
    warn "Add the following kernel parameters manually: splash quiet"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
printf '\n'
ok "════════════════════════════════════════════════════"
ok "  Kage-Ryu Plymouth boot splash installed!"
ok ""
ok "  Theme:   ${THEME_NAME}"
ok "  Files:   ${THEME_DIR}/"
ok ""
ok "  Backups created:"
ok "    /etc/mkinitcpio.conf.bak"
[[ -f "${GRUB_DEFAULT}" ]] && ok "    /etc/default/grub.bak"
ok ""
ok "  Reboot to see the new boot splash screen."
ok "════════════════════════════════════════════════════"
