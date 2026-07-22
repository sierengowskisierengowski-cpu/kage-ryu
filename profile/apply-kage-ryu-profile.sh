#!/usr/bin/env bash
# ============================================================================
#  apply-kage-ryu-profile.sh — deploy the Kage-Ryu Nyxus machine activation
#  layer onto THIS host. Turns the kernel's already-compiled capabilities
#  (sched-ext, PREEMPT_DYNAMIC, nested KVM, GuC, BBR) into a live, machine-
#  tuned profile. No kernel rebuild required.
#
#  © 2026 Joseph A. Sierengowski — Kage Ryu Nyxus.
#
#  SAFE BY DEFAULT. A bare run only installs reversible drop-ins:
#    - /etc/sysctl.d/99-kage-ryu.conf        (network + lab tuning)
#    - /etc/modprobe.d/kage-ryu.conf         (kvm nested, i915 GuC)
#    - /usr/local/bin/kage-ryu-scx           (scheduler launcher)
#    - /etc/systemd/system/scx-kage-ryu.service   (installed, NOT enabled)
#
#  Opt-in flags (each is independent):
#    --enable-scx   enable + start the sched-ext scheduler now (needs scx-scheds)
#    --cmdline      append the recommended params to the Kage-Ryu BOOT ENTRY
#                   ONLY (stock `linux` entry is never touched)
#    --uninstall    remove everything this script installs
#
#  Usage:  sudo ./apply-kage-ryu-profile.sh [--enable-scx] [--cmdline]
# ============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO_SCX=0
DO_CMDLINE=0
DO_UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --enable-scx) DO_SCX=1 ;;
    --cmdline)    DO_CMDLINE=1 ;;
    --uninstall)  DO_UNINSTALL=1 ;;
    -h|--help)    sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then echo "run: sudo $0 $*" >&2; exit 1; fi

say()  { printf '  \033[1;35m·\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }

# ── uninstall ───────────────────────────────────────────────────────────────
if [[ $DO_UNINSTALL -eq 1 ]]; then
  echo "▌ Removing Kage-Ryu machine profile"
  systemctl disable --now scx-kage-ryu.service 2>/dev/null || true
  rm -f /etc/sysctl.d/99-kage-ryu.conf /etc/modprobe.d/kage-ryu.conf \
        /usr/local/bin/kage-ryu-scx /etc/systemd/system/scx-kage-ryu.service
  systemctl daemon-reload 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  ok "removed (a reboot fully clears modprobe/cmdline effects)"
  exit 0
fi

echo "▌ Kage-Ryu Nyxus machine profile"

# ── sysctl + modprobe drop-ins ──────────────────────────────────────────────
install -Dm644 "${SRC_DIR}/sysctl.d/99-kage-ryu.conf"   /etc/sysctl.d/99-kage-ryu.conf
ok "sysctl  → /etc/sysctl.d/99-kage-ryu.conf"
# Retire the older, narrower drop-in so the two don't fight; 99-kage-ryu is a
# strict superset (same BBR/FQ keys plus the lab/network tuning).
if [[ -e /etc/sysctl.d/99-nyxus-bbr.conf ]]; then
  rm -f /etc/sysctl.d/99-nyxus-bbr.conf
  say "superseded and removed /etc/sysctl.d/99-nyxus-bbr.conf"
fi
install -Dm644 "${SRC_DIR}/modprobe.d/kage-ryu.conf"    /etc/modprobe.d/kage-ryu.conf
ok "modprobe → /etc/modprobe.d/kage-ryu.conf (kvm nested, i915 GuC — reboot to apply)"
if sysctl --system >/dev/null 2>&1; then ok "sysctl reloaded"; else warn "sysctl reload deferred to reboot"; fi

# ── sched-ext scheduler launcher + unit ─────────────────────────────────────
install -Dm755 "${SRC_DIR}/bin/kage-ryu-scx"            /usr/local/bin/kage-ryu-scx
install -Dm644 "${SRC_DIR}/systemd/scx-kage-ryu.service" /etc/systemd/system/scx-kage-ryu.service
systemctl daemon-reload
ok "sched-ext launcher + unit installed (not enabled)"

if [[ ! -e /sys/kernel/sched_ext ]]; then
  warn "running kernel has no sched_ext — boot into Kage-Ryu to use scx-kage-ryu"
fi

if [[ $DO_SCX -eq 1 ]]; then
  if compgen -G "/usr/bin/scx_*" >/dev/null 2>&1 || command -v scx_lavd >/dev/null 2>&1; then
    systemctl enable --now scx-kage-ryu.service && ok "sched-ext scheduler enabled + started"
    systemctl --no-pager --lines=0 status scx-kage-ryu.service 2>/dev/null | head -3 || true
  else
    warn "--enable-scx requested but no scx scheduler installed"
    warn "run:  sudo pacman -S scx-scheds   then:  sudo systemctl enable --now scx-kage-ryu"
  fi
else
  say "sched-ext left disabled. Enable later with:"
  say "  sudo pacman -S scx-scheds && sudo systemctl enable --now scx-kage-ryu"
fi

# ── boot cmdline (opt-in, Kage-Ryu entry only) ─────────────────────────────
if [[ $DO_CMDLINE -eq 1 ]]; then
  # shellcheck source=/dev/null
  source "${SRC_DIR}/cmdline.conf"
  PARAMS="${KAGE_RYU_CMDLINE:-}"
  [[ -z "$PARAMS" ]] && { warn "cmdline.conf had no KAGE_RYU_CMDLINE"; PARAMS=""; }

  applied=0
  # systemd-boot: per-entry .conf — safest, we can target the kage-ryu entry.
  if [[ -d /boot/loader/entries ]]; then
    shopt -s nullglob
    for entry in /boot/loader/entries/*kage-ryu*.conf; do
      if ! grep -q 'KAGE-RYU-PROFILE' "$entry"; then
        printf 'options %s # KAGE-RYU-PROFILE\n' "$PARAMS" >> "$entry"
        ok "systemd-boot: appended params to $(basename "$entry")"
        applied=1
      else
        say "systemd-boot: $(basename "$entry") already has profile params"
        applied=1
      fi
    done
    shopt -u nullglob
  fi

  if [[ $applied -eq 0 ]]; then
    warn "could not auto-edit a Kage-Ryu boot entry (GRUB or no entry yet)."
    warn "GRUB users: add these to the kage-ryu menuentry, or to"
    warn "GRUB_CMDLINE_LINUX_DEFAULT (note: that also affects stock linux):"
    printf '        \033[1;36m%s\033[0m\n' "$PARAMS"
  fi
else
  say "boot cmdline NOT modified. Re-run with --cmdline to apply (Kage-Ryu entry only)."
fi

echo
ok "Kage-Ryu machine profile applied. Reboot into Kage-Ryu to pick up modprobe/cmdline."
