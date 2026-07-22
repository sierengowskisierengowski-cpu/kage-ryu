#!/usr/bin/env bash
# ============================================================================
#  install-activation.sh — install the Kage-Ryu auto-activation layer.
#
#  Puts the profile + scheduler assets, the pacman hook, the activator, and
#  the systemd preset onto a system so the Kage-Ryu kernel activates itself:
#    * on every `pacman -U/-Syu` of linux-kage-ryu (the hook), and
#    * on first boot of a freshly-installed / live image (the preset + the
#      drop-ins staged straight into the rootfs).
#
#  Two modes:
#    bare metal :  sudo ./install-activation.sh
#                  installs into THIS system and runs the activator once.
#    into rootfs:  ./install-activation.sh --root DIR
#                  stages everything into DIR (e.g. an archiso airootfs) with
#                  the scheduler pre-enabled — it comes up on the image's
#                  first boot. Does NOT run the activator (wrong system).
#
#  © 2026 Joseph A. Sierengowski — Kage Ryu Nyxus.
# ============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root: has profile/ scheduler/
ROOT=""
case "${1:-}" in
  --root) ROOT="${2:?--root needs a directory}" ;;
  "" ) : ;;
  -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

D="$ROOT"   # destination prefix ("" == live system)
if [[ -z "$ROOT" && $EUID -ne 0 ]]; then
  echo "bare-metal install needs root: sudo $0" >&2; exit 1
fi

say() { printf '  \033[1;35m·\033[0m %s\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

echo "▌ Kage-Ryu auto-activation layer ${ROOT:+(staging into $ROOT)}"

# ── shared assets: profile + scheduler sources → /usr/share/kage-ryu ─────────
install -d "$D/usr/share/kage-ryu"
cp -a "$SRC/profile"   "$D/usr/share/kage-ryu/"
cp -a "$SRC/scheduler" "$D/usr/share/kage-ryu/"
# don't ship build artifacts
rm -f "$D/usr/share/kage-ryu/scheduler/scx_kage" \
      "$D/usr/share/kage-ryu/scheduler/scx_kage.bpf.o" \
      "$D/usr/share/kage-ryu/scheduler/scx_kage.skel.h" \
      "$D/usr/share/kage-ryu/scheduler/vmlinux.h" 2>/dev/null || true
ok "assets → /usr/share/kage-ryu/{profile,scheduler}"

# ── pacman hook + activator ─────────────────────────────────────────────────
install -Dm755 "$SRC/packaging/kage-ryu-activate" \
  "$D/usr/share/libalpm/scripts/kage-ryu-activate"
install -Dm644 "$SRC/packaging/hooks/95-kage-ryu-activate.hook" \
  "$D/usr/share/libalpm/hooks/95-kage-ryu-activate.hook"
ok "pacman hook + activator installed (re-applies on every kernel upgrade)"

# ── systemd preset ──────────────────────────────────────────────────────────
install -Dm644 "$SRC/packaging/systemd-preset/80-kage-ryu.preset" \
  "$D/usr/lib/systemd/system-preset/80-kage-ryu.preset"
ok "systemd preset installed (enable scx-kage.service)"

if [[ -n "$ROOT" ]]; then
  # ── rootfs / airootfs staging: make first boot already tuned ──────────────
  # Drop-ins the running kernel reads at boot go straight into place.
  install -Dm644 "$SRC/profile/sysctl.d/99-kage-ryu.conf"  "$D/etc/sysctl.d/99-kage-ryu.conf"
  install -Dm644 "$SRC/profile/modprobe.d/kage-ryu.conf"   "$D/etc/modprobe.d/kage-ryu.conf"
  install -Dm644 "$SRC/scheduler/systemd/scx-kage.service" "$D/etc/systemd/system/scx-kage.service"

  # Pre-build scx_kage into the image if the toolchain is on the BUILD host,
  # so the live/installed system doesn't have to compile on first boot.
  if command -v clang >/dev/null 2>&1 && command -v bpftool >/dev/null 2>&1; then
    if make -C "$SRC/scheduler" >/dev/null 2>&1; then
      install -Dm755 "$SRC/scheduler/scx_kage"     "$D/usr/local/bin/scx_kage"
      install -Dm755 "$SRC/scheduler/scx_kage_ctl" "$D/usr/local/bin/scx_kage_ctl"
      make -C "$SRC/scheduler" clean >/dev/null 2>&1 || true
      ok "pre-built scx_kage staged → /usr/local/bin (no first-boot compile)"
    else
      say "scx_kage pre-build failed on host; the activator will build it on first kernel event"
    fi
  else
    install -Dm755 "$SRC/scheduler/scx_kage_ctl" "$D/usr/local/bin/scx_kage_ctl"
    say "no clang/bpftool on build host; scx_kage builds on the target's first kernel event"
  fi

  # Enable the scheduler for first boot without running systemctl in the image.
  install -d "$D/etc/systemd/system/multi-user.target.wants"
  ln -sf ../scx-kage.service \
    "$D/etc/systemd/system/multi-user.target.wants/scx-kage.service"
  ok "scx-kage.service enabled in image (starts on first Kage-Ryu boot)"

  echo
  ok "staged into $ROOT — a Kage-Ryu boot from this image is tuned + scheduled automatically"
else
  # ── bare metal: run the activator now ─────────────────────────────────────
  echo
  say "running activator on this system…"
  /usr/share/libalpm/scripts/kage-ryu-activate
fi
