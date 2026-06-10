#!/usr/bin/env bash
# =============================================================================
# sensor/uninstall.sh — Kage-Ryu Sensor Stack Teardown
# =============================================================================

set -euo pipefail

SENSOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\e[36m[INFO]\e[0m  %s\n' "$*"; }
ok() { printf '\e[32m[ OK ]\e[0m  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { printf '\e[31m[FAIL]\e[0m  Run as root.\n' >&2; exit 1; }

info "Stopping services…"
for unit in jett.service bifrost-guardian.service kage-sensor.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
done

info "Removing systemd units…"
rm -f /etc/systemd/system/jett.service \
      /etc/systemd/system/bifrost-guardian.service \
      /etc/systemd/system/kage-sensor.service

info "Removing installed sensor files…"
rm -f /usr/bin/jett_daemon
rm -rf /usr/lib/bifrost
rm -f /usr/lib/bpf/kage_sensor.bpf.o
rm -f /etc/logrotate.d/jett
rm -rf /var/log/jett
rm -rf /sys/fs/bpf/kage

info "Reloading systemd…"
systemctl daemon-reload

ok "Sensor stack removed."
