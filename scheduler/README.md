# scx_kage — the Kage-Ryu sched-ext CPU scheduler

A **custom BPF CPU scheduler** written for the Kage-Ryu kernel. It runs in
userspace-loaded BPF on top of `CONFIG_SCHED_CLASS_EXT=y` and does two things
no off-the-shelf scheduler does together:

1. **Intel hybrid (P/E core) awareness.** On Alder Lake it keeps interactive
   and trusted work on the fast **Performance cores** and pushes untrusted /
   penalised work onto the **Efficiency cores**.

2. **EDR coupling.** It shares a pinned `quarantine` BPF map with the kage
   eBPF sensor / jeTT AI EDR. The moment jeTT flags a process, that process is
   **demoted at the CPU level** — strictly confined to the E-cores with a
   quarter-length time slice — *before it is ever killed*. Untrusted samples
   can't steal a Performance core from the tools watching them.

The built-in EEVDF scheduler is restored automatically the instant `scx_kage`
exits, crashes, or is stopped — so it is always safe to start and stop.

## How it schedules

| Task | Where it runs |
|---|---|
| Normal / trusted / interactive | `SHARED_DSQ`, preferred on **P-cores** (E-cores help when idle) |
| Quarantined (in the EDR map) | `PENALTY_DSQ`, **E-cores only**, short slice — never climbs to a P-core |

If the CPU is **homogeneous** (no E-cores detected via `cpu_capacity`), the
scheduler degrades gracefully: penalised tasks still run, but only after all
normal work is drained (a starvation-safe CPU penalty rather than isolation).

The P/E split is discovered at load time from
`/sys/devices/system/cpu/cpuN/cpu_capacity` and handed to the BPF program as a
core mask — nothing is hard-coded to a specific CPU.

## Build

Requires `clang`, `bpftool`, `libbpf` (+ headers), `llvm-strip`. `vmlinux.h` is
generated from the running kernel's BTF, so it always matches your kernel.

```bash
make
```

Produces `scx_kage` (loader) and the BPF object/skeleton.

## Run

Attaching a sched-ext scheduler needs **root** and a `SCHED_CLASS_EXT` kernel
(boot into Kage-Ryu). Quick foreground test:

```bash
sudo ./scx_kage
# → "running — hybrid mode, N E-core(s) ..." (or homogeneous mode)
# Ctrl-C to detach and revert to EEVDF.
```

Verify it is the live scheduler from another terminal:

```bash
cat /sys/kernel/sched_ext/root/ops     # → kage
```

Install and run as a service:

```bash
sudo make install                       # /usr/local/bin + /etc/systemd/system
sudo systemctl enable --now scx-kage    # ConditionPathExists gates it safely
```

## Demote / restore processes

`scx_kage_ctl` writes the same pinned map jeTT uses, so a manual demote and an
AI verdict share one path:

```bash
sudo scx_kage_ctl demote  <pid>     # confine to E-cores, short slice
sudo scx_kage_ctl restore <pid>     # back to normal scheduling
sudo scx_kage_ctl list              # show penalised tgids
sudo scx_kage_ctl status            # which scheduler is active
```

The map is pinned at `/sys/fs/bpf/scx_kage_quarantine`. jeTT can demote a
suspicious PID there the instant it scores it — CPU-level containment that
lands before the kill.

## Notes / status

- Builds clean against the running kernel's BTF; all sched-ext kfuncs, types,
  and `SCX_*` constants are resolved from `/sys/kernel/btf/vmlinux`.
- The load → verify → attach step is root-gated; run the `sudo ./scx_kage`
  test above on a booted Kage-Ryu kernel to confirm attach on your box.
- Only one sched-ext scheduler can be attached at a time; the unit declares
  `Conflicts=scx-kage-ryu.service` so it won't fight the generic launcher.

© 2026 Joseph A. Sierengowski — Kage Ryu Nyxus.
