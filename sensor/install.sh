#!/usr/bin/env bash
# =============================================================================
# sensor/install.sh — Kage-Ryu Sensor Stack Installer
# =============================================================================
#
# Prerequisites (Arch Linux):
#   - linux-kage-ryu kernel (or any kernel with BTF and LSM eBPF support)
#   - bpftool          (pacman -S bpf)
#   - clang + llvm     (pacman -S clang llvm)
#   - libbpf           (pacman -S libbpf)
#   - python3          (for Bifrost Guardian)
#   - systemd          (standard Arch init)
#   - cargo / rustup   (for building jeTT from source, if no pre-built binary)
#   - plymouth         (pacman -S plymouth)  — for boot splash (optional)
#
# Usage:
#   sudo bash sensor/install.sh
#
# What this script does (in order):
#   1. Generates vmlinux.h from the running kernel's BTF data
#   2. Compiles kage_sensor.bpf.c to a BPF object
#   3. Copies the BPF artifact to /usr/lib/bpf/
#   4. Installs Bifrost Guardian (Python daemon)
#   5. Installs jeTT (pre-built binary or builds from source)
#   6. Installs systemd service units
#   7. Enables services in dependency order:
#         kage-sensor → bifrost-guardian → jett
#   8. Installs the kage-ryu Plymouth boot splash (non-fatal)
# =============================================================================

set -euo pipefail

SENSOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BPF_OUTPUT_DIR="/usr/lib/bpf"
BIFROST_LIB_DIR="/usr/lib/bifrost"
JETT_BIN="/usr/bin/jett_daemon"
LOG_DIR="/var/log/jett"

# ── Colour helpers ────────────────────────────────────────────────────────────
info()  { printf '\e[36m[INFO]\e[0m  %s\n'  "$*"; }
ok()    { printf '\e[32m[ OK ]\e[0m  %s\n'  "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n'  "$*"; }
die()   { printf '\e[31m[FAIL]\e[0m  %s\n'  "$*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)."

# ── Dependency checks ─────────────────────────────────────────────────────────
info "Checking required tools…"
for cmd in bpftool clang python3 systemctl install; do
    command -v "$cmd" &>/dev/null || die "Required command not found: ${cmd}. See prerequisites above."
done
ok "All required tools present."

# ── Step 1: Generate vmlinux.h ────────────────────────────────────────────────
info "Generating vmlinux.h from /sys/kernel/btf/vmlinux…"
[[ -r /sys/kernel/btf/vmlinux ]] \
    || die "/sys/kernel/btf/vmlinux not found or not readable. Ensure the running kernel was built with CONFIG_DEBUG_INFO_BTF=y."
bpftool btf dump file /sys/kernel/btf/vmlinux format c > "${SENSOR_DIR}/vmlinux.h"
ok "vmlinux.h generated at ${SENSOR_DIR}/vmlinux.h."

# ── Step 2: Compile kage_sensor.bpf.c ────────────────────────────────────────
info "Compiling kage_sensor.bpf.c…"
[[ -f "${SENSOR_DIR}/kage_sensor.bpf.c" ]] \
    || die "Source not found: ${SENSOR_DIR}/kage_sensor.bpf.c"

clang \
    -g -O2 \
    -target bpf \
    -D__TARGET_ARCH_x86 \
    -I"${SENSOR_DIR}" \
    -c "${SENSOR_DIR}/kage_sensor.bpf.c" \
    -o "${SENSOR_DIR}/kage_sensor.bpf.o"
ok "BPF object compiled: ${SENSOR_DIR}/kage_sensor.bpf.o"

# ── Step 3: Install BPF artifact ─────────────────────────────────────────────
info "Installing BPF object to ${BPF_OUTPUT_DIR}/…"
install -d "${BPF_OUTPUT_DIR}"
install -m 644 "${SENSOR_DIR}/kage_sensor.bpf.o" "${BPF_OUTPUT_DIR}/kage_sensor.bpf.o"
ok "BPF object installed."

# ── Step 4: Install Bifrost Guardian ─────────────────────────────────────────
info "Installing Bifrost Guardian to ${BIFROST_LIB_DIR}/…"
install -d "${BIFROST_LIB_DIR}"
install -m 755 "${SENSOR_DIR}/bifrost_guardian.py" "${BIFROST_LIB_DIR}/bifrost_guardian.py"
ok "Bifrost Guardian installed."

# ── Step 5: Install jeTT daemon ──────────────────────────────────────────────
if [[ -f "${SENSOR_DIR}/jett_daemon" ]]; then
    info "Installing pre-built jeTT daemon binary…"
    install -m 755 "${SENSOR_DIR}/jett_daemon" "${JETT_BIN}"
    ok "jeTT daemon installed from pre-built binary."
elif command -v cargo &>/dev/null && [[ -f "${SENSOR_DIR}/Cargo.toml" ]]; then
    info "Building jeTT daemon from source (this may take a while)…"
    (cd "${SENSOR_DIR}" && cargo build --release) || die "jeTT build failed. Check cargo output above."
    install -m 755 "${SENSOR_DIR}/target/release/jett_daemon" "${JETT_BIN}"
    ok "jeTT daemon built and installed."
else
    warn "No pre-built jeTT binary found and cargo is unavailable."
    warn "Build manually: cd sensor && cargo build --release"
    warn "Then re-run this script, or copy the binary to ${JETT_BIN}."
fi

# ── Step 6: Create log directory ─────────────────────────────────────────────
install -d "${LOG_DIR}"
ok "Log directory ${LOG_DIR} ready."

# ── Step 7: Install systemd service units ────────────────────────────────────
info "Installing systemd service units…"
for unit in kage-sensor.service bifrost-guardian.service jett.service; do
    src="${SENSOR_DIR}/systemd/${unit}"
    [[ -f "$src" ]] || die "Service unit not found: ${src}"
    install -m 644 "$src" "/etc/systemd/system/${unit}"
done
ok "Systemd units installed."

# Install logrotate config if present
if [[ -f "${SENSOR_DIR}/logrotate.conf" ]]; then
    install -d /etc/logrotate.d
    install -m 644 "${SENSOR_DIR}/logrotate.conf" /etc/logrotate.d/jett
    ok "Logrotate config installed to /etc/logrotate.d/jett."
fi

# ── Step 8: Enable services in correct dependency order ──────────────────────
info "Reloading systemd daemon…"
systemctl daemon-reload

# Start in order: BPF sensor first, then Bifrost socket server, then jeTT consumer
for unit in kage-sensor.service bifrost-guardian.service jett.service; do
    info "Enabling and starting ${unit}…"
    systemctl enable --now "${unit}"
    ok "${unit} enabled and started."
done

# ── Step 8 (optional): Install Plymouth boot splash ───────────────────────────
SPLASH_INSTALLER="$(cd "${SENSOR_DIR}/.." && pwd)/splash/install-splash.sh"
if [[ -f "${SPLASH_INSTALLER}" ]]; then
    info "Installing Kage-Ryu Plymouth boot splash…"
    bash "${SPLASH_INSTALLER}" || warn "Boot splash installation failed — sensor stack is unaffected."
else
    warn "Splash installer not found at ${SPLASH_INSTALLER} — skipping boot splash setup."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
printf '\n'
ok "════════════════════════════════════════════════════"
ok "  Kage-Ryu Sensor Stack installed successfully!"
ok ""
ok "  Services running:"
ok "    ● kage-sensor.service      (BPF loader)"
ok "    ● bifrost-guardian.service (socket server)"
ok "    ● jett.service             (eBPF event daemon)"
ok ""
ok "  Boot splash: kage-ryu Plymouth theme installed."
ok ""
ok "  Run:  sensor/kage-status    to verify health"
ok "  Logs: journalctl -u jett     to inspect events"
ok "  Reboot to see the boot splash screen."
ok "════════════════════════════════════════════════════"
