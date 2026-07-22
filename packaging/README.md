# Kage-Ryu auto-activation layer

This turns the manual profile + scheduler into something that **installs and
runs itself**, so the Kage-Ryu kernel is bound to the machine automatically —
both on a running system and inside a freshly-built Nyxus image.

Two mechanisms:

| Mechanism | What it does |
|---|---|
| **pacman hook** (`95-kage-ryu-activate.hook`) | On every install/upgrade of `linux-kage-ryu`, runs the activator so an update never silently reverts your tuning or leaves the scheduler un-enabled |
| **rootfs staging + systemd preset** | Bakes the tuning drop-ins, the pre-built `scx_kage` scheduler, and an *enabled* `scx-kage.service` straight into an image, so its **first boot is already tuned and scheduled** |

## Files

| File | Installs to | Role |
|---|---|---|
| `kage-ryu-activate` | `/usr/share/libalpm/scripts/` | idempotent activator (tuning + cmdline + scheduler enable) |
| `hooks/95-kage-ryu-activate.hook` | `/usr/share/libalpm/hooks/` | fires the activator on kernel install/upgrade |
| `systemd-preset/80-kage-ryu.preset` | `/usr/lib/systemd/system-preset/` | enables `scx-kage.service` by default |
| `install-activation.sh` | — | installs all of the above (bare metal or into a rootfs) |

The activator **enables** the scheduler for the next boot; it never *starts* it
mid-pacman-transaction (swapping the live CPU scheduler during an upgrade would
be reckless). `scx-kage.service` carries `ConditionPathExists=/sys/kernel/sched_ext`,
so enabling it by default is a clean no-op on any non-Kage-Ryu kernel.

## Usage

```bash
# Bare metal: install the hook + preset + assets and activate now.
sudo ./install-activation.sh

# Into an image (archiso airootfs): stage everything, scheduler pre-enabled.
./install-activation.sh --root /path/to/airootfs
```

In Nyxus-Core both are wired for you: `kernel/install-kage-ryu.sh` calls the
bare-metal path after installing the kernel, and `iso-builder/build-iso.sh`
(with `NYX_WITH_KAGE_RYU=1`) calls the `--root` path against the ISO airootfs.

## What a fresh Kage-Ryu boot then gets, with no manual step

- BBR+FQ, container/inotify limits, MGLRU reclaim, BPF hardening (sysctl)
- nested-KVM + Intel GuC/HuC (modprobe)
- `preempt=full` and friends on the Kage-Ryu boot entry only (cmdline)
- `scx_kage` running — P/E-core aware, coupled to the eBPF EDR

© 2026 Joseph A. Sierengowski — Kage Ryu Nyxus.
