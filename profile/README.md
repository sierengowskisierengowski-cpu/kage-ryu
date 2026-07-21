# Kage-Ryu Nyxus — Machine Activation Profile

The Kage-Ryu kernel is a XanMod 7.0 base with a maxed-out config: sched-ext,
Intel Thread Director (HFI), the full LSM stack, eBPF/BTF depth, nested KVM,
BBR, MGLRU, io_uring — it's all compiled in. **This folder is what turns those
dormant capabilities into a live profile bound to the exact machine and mission
this kernel was built for** (MSI GS77 · i7-12700H Alder Lake · RTX 3060 ·
eBPF EDR + Docker honeypot fleet + malware-detonation VMs).

None of this requires recompiling the kernel — it's a pure activation layer.

## What's here

| File | Deploys to | Effect |
|---|---|---|
| `sysctl.d/99-kage-ryu.conf` | `/etc/sysctl.d/` | BBR+FQ, big socket buffers, container/inotify limits, MGLRU-friendly reclaim, BPF surface hardening |
| `modprobe.d/kage-ryu.conf` | `/etc/modprobe.d/` | `kvm_intel nested=1` (detonation VMs), `i915 enable_guc=3` |
| `cmdline.conf` | boot entry | `preempt=full`, NVIDIA/i915 KMS, `split_lock_detect=off` |
| `bin/kage-ryu-scx` | `/usr/local/bin/` | picks the best installed sched-ext scheduler (`scx_lavd` first) |
| `systemd/scx-kage-ryu.service` | `/etc/systemd/system/` | runs the BPF CPU scheduler (disabled by default) |
| `apply-kage-ryu-profile.sh` | — | idempotent installer for all of the above |

## Why it's one-of-a-kind

- **A BPF-scheduled security kernel.** `CONFIG_SCHED_CLASS_EXT=y` lets userspace
  *be* the CPU scheduler. `scx-kage-ryu.service` runs `scx_lavd` (latency-aware)
  so interactive/gaming latency stays low even under a full detonation +
  CUDA + compile load — and it pairs naturally with the eBPF EDR in `sensor/`.
- **`preempt=full` with no rebuild.** The kernel is `PREEMPT_DYNAMIC`, so full
  preemption is a boot choice — realized here via cmdline, reversible per boot.
- **Tuned to the silicon.** Alder Lake GuC/HuC, nested VT-x for lab VMs,
  split-lock detection off for wine/games.
- **Security-first defaults.** Because this box runs untrusted samples, the
  profile keeps kernel info-leak knobs (kptr/perf) at safe defaults and keeps
  CPU mitigations available — it does *not* trade safety for benchmarks.

## Usage

```bash
# Safe baseline: sysctl + modprobe + scheduler launcher (nothing enabled)
sudo ./apply-kage-ryu-profile.sh

# Turn on the sched-ext scheduler (installs scx-scheds first if needed)
sudo pacman -S scx-scheds
sudo ./apply-kage-ryu-profile.sh --enable-scx

# Also inject the recommended boot params into the Kage-Ryu entry ONLY
sudo ./apply-kage-ryu-profile.sh --cmdline

# Full teardown
sudo ./apply-kage-ryu-profile.sh --uninstall
```

The stock `linux` boot entry is never modified — a bad param can't strand you.
