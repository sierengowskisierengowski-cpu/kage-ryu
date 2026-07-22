// SPDX-License-Identifier: GPL-2.0
/*
 * scx_kage — the Kage-Ryu sched-ext BPF CPU scheduler.
 *
 * A custom sched_ext scheduler purpose-built for the Kage-Ryu security-lab
 * box. Two things make it one-of-a-kind:
 *
 *   1. Intel hybrid (P/E core) awareness. On Alder Lake the scheduler keeps
 *      interactive + trusted work on the fast Performance cores and pushes
 *      untrusted work onto the Efficiency cores.
 *
 *   2. EDR coupling. It shares a `quarantine` BPF map with the kage eBPF
 *      sensor / jeTT AI EDR. The instant jeTT flags a process, that process
 *      is *demoted at the CPU level* — strictly confined to the E-cores with
 *      a short time slice — before it is ever killed. Untrusted samples can
 *      never steal a Performance core from the tools watching them.
 *
 * No scx_common.bpf.h is required: the few struct_ops macros are defined
 * inline in terms of libbpf's BPF_PROG, and the kfunc prototypes are declared
 * directly (all verified present in this kernel's BTF).
 *
 * © 2026 Joseph A. Sierengowski — Kage Ryu Nyxus.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

char _license[] SEC("license") = "GPL";

/* --- struct_ops glue (scx's common.bpf.h is not installed) ---------------- */
#define BPF_STRUCT_OPS(name, args...) \
	SEC("struct_ops/" #name) BPF_PROG(name, ##args)
#define BPF_STRUCT_OPS_SLEEPABLE(name, args...) \
	SEC("struct_ops.s/" #name) BPF_PROG(name, ##args)

/* --- sched_ext kfuncs (verified present in this kernel's vmlinux BTF) ------ */
s32  scx_bpf_create_dsq(u64 dsq_id, s32 node) __ksym;
void scx_bpf_dsq_insert(struct task_struct *p, u64 dsq_id, u64 slice, u64 enq_flags) __ksym;
bool scx_bpf_dsq_move_to_local(u64 dsq_id) __ksym;
s32  scx_bpf_select_cpu_dfl(struct task_struct *p, s32 prev_cpu, u64 wake_flags, bool *is_idle) __ksym;

/* --- config, filled in by userspace before load (.rodata) ----------------- */
/* bit i set => cpu i is an Efficiency core. 0 => homogeneous machine. */
const volatile u64 e_core_mask = 0;
const volatile u32 nr_cpus     = 1;

/* --- dispatch queues ------------------------------------------------------ */
/* Arbitrary ids; must avoid the SCX_DSQ_* high-bit special values. */
#define SHARED_DSQ   0	/* trusted / interactive work */
#define PENALTY_DSQ  1	/* quarantined / untrusted work */

/* Quarantined tasks run on a short slice so they yield often. */
#define SLICE_PENALTY (SCX_SLICE_DFL / 4)

/* --- EDR coupling --------------------------------------------------------- */
/* Shared with the kage sensor / jeTT. A tgid present here (value != 0) is
 * quarantined. Pinned so jeTT and scx_kage_ctl can update it live while the
 * scheduler runs. */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 4096);
	__type(key, u32);
	__type(value, u32);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} quarantine SEC(".maps");

/* --- live stats (read by userspace) --------------------------------------- */
u64 nr_normal;
u64 nr_penalty;

static __always_inline bool is_quarantined(struct task_struct *p)
{
	u32 tgid = p->tgid;
	u32 *v = bpf_map_lookup_elem(&quarantine, &tgid);

	return v && *v;
}

static __always_inline bool cpu_is_ecore(s32 cpu)
{
	if (cpu < 0 || cpu >= 64)
		return false;
	return e_core_mask & (1ULL << cpu);
}

s32 BPF_STRUCT_OPS(kage_select_cpu, struct task_struct *p, s32 prev_cpu,
		   u64 wake_flags)
{
	bool is_idle = false;
	s32 cpu;

	/* Quarantined tasks never get a fast idle-core direct dispatch — force
	 * them through enqueue() so they can only ever reach PENALTY_DSQ. */
	if (is_quarantined(p))
		return prev_cpu;

	cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
	if (is_idle)
		scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
	return cpu;
}

void BPF_STRUCT_OPS(kage_enqueue, struct task_struct *p, u64 enq_flags)
{
	if (is_quarantined(p)) {
		__sync_fetch_and_add(&nr_penalty, 1);
		scx_bpf_dsq_insert(p, PENALTY_DSQ, SLICE_PENALTY, enq_flags);
	} else {
		__sync_fetch_and_add(&nr_normal, 1);
		scx_bpf_dsq_insert(p, SHARED_DSQ, SCX_SLICE_DFL, enq_flags);
	}
}

void BPF_STRUCT_OPS(kage_dispatch, s32 cpu, struct task_struct *prev)
{
	bool homogeneous = (e_core_mask == 0);

	if (cpu_is_ecore(cpu)) {
		/* E-core: draining the penalty domain is its whole job; when
		 * that's empty it helps out with normal work. */
		if (scx_bpf_dsq_move_to_local(PENALTY_DSQ))
			return;
		scx_bpf_dsq_move_to_local(SHARED_DSQ);
		return;
	}

	if (homogeneous) {
		/* No hardware isolation to hand: still penalise untrusted work
		 * by only running it once normal work is drained. Draining it
		 * last (rather than never) guarantees no starvation. */
		if (scx_bpf_dsq_move_to_local(SHARED_DSQ))
			return;
		scx_bpf_dsq_move_to_local(PENALTY_DSQ);
		return;
	}

	/* Hybrid P-core: trusted work ONLY. Quarantined tasks are strictly
	 * confined to the E-cores and can never climb onto a Performance core. */
	scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

s32 BPF_STRUCT_OPS_SLEEPABLE(kage_init)
{
	s32 ret;

	ret = scx_bpf_create_dsq(SHARED_DSQ, -1);
	if (ret)
		return ret;
	return scx_bpf_create_dsq(PENALTY_DSQ, -1);
}

void BPF_STRUCT_OPS(kage_exit, struct scx_exit_info *ei)
{
	/* Kernel reverts to built-in EEVDF automatically on detach. */
}

SEC(".struct_ops.link")
struct sched_ext_ops kage_ops = {
	.select_cpu = (void *)kage_select_cpu,
	.enqueue    = (void *)kage_enqueue,
	.dispatch   = (void *)kage_dispatch,
	.init       = (void *)kage_init,
	.exit       = (void *)kage_exit,
	.flags      = 0,
	.name       = "kage",
};
