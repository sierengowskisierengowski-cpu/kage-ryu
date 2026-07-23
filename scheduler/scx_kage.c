// SPDX-License-Identifier: GPL-2.0
/*
 * scx_kage — userspace loader for the Kage-Ryu sched-ext scheduler.
 *
 * Detects Intel hybrid Efficiency cores from sysfs cpu_capacity, hands the
 * mask to the BPF scheduler, attaches it, then idles until SIGINT/SIGTERM.
 * On exit the kernel transparently reverts to the built-in EEVDF scheduler,
 * so this is always safe to start and stop.
 *
 * © 2026 Joseph A. Sierengowski — Kage Ryu Nyxus.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <errno.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include "scx_kage.skel.h"

#define QUARANTINE_PIN "/sys/fs/bpf/scx_kage_quarantine"
#define MAX_CPUS 64

static volatile sig_atomic_t exit_req;
static void on_signal(int sig) { exit_req = 1; }

static int libbpf_quiet(enum libbpf_print_level lvl, const char *fmt, va_list ap)
{
	if (lvl == LIBBPF_DEBUG)
		return 0;
	return vfprintf(stderr, fmt, ap);
}

/*
 * Detect Efficiency cores via /sys/devices/system/cpu/cpuN/cpu_capacity.
 * On Intel hybrid parts P-cores report the max capacity (1024) and E-cores
 * report less. If the file is absent or every core is equal, the machine is
 * treated as homogeneous (mask 0) and the scheduler degrades gracefully.
 */
static unsigned long long detect_ecores(unsigned int *nr_out)
{
	unsigned int nr = sysconf(_SC_NPROCESSORS_ONLN);
	unsigned long cap[MAX_CPUS];
	unsigned long maxcap = 0;
	unsigned long long mask = 0;
	unsigned int i, have_caps = 0;

	if (nr > MAX_CPUS)
		nr = MAX_CPUS;

	for (i = 0; i < nr; i++) {
		char path[128];
		FILE *f;

		cap[i] = 0;
		snprintf(path, sizeof(path),
			 "/sys/devices/system/cpu/cpu%u/cpu_capacity", i);
		f = fopen(path, "r");
		if (f) {
			if (fscanf(f, "%lu", &cap[i]) == 1 && cap[i] > 0)
				have_caps = 1;
			fclose(f);
		}
		if (cap[i] > maxcap)
			maxcap = cap[i];
	}

	if (have_caps && maxcap > 0) {
		for (i = 0; i < nr; i++)
			if (cap[i] > 0 && cap[i] < maxcap)
				mask |= (1ULL << i);
	}

	*nr_out = nr;
	return mask;
}

int main(int argc, char **argv)
{
	struct scx_kage *skel;
	struct bpf_link *link;
	unsigned long long emask;
	unsigned int nr;

	libbpf_set_print(libbpf_quiet);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	emask = detect_ecores(&nr);

	skel = scx_kage__open();
	if (!skel) {
		fprintf(stderr, "scx_kage: failed to open BPF skeleton\n");
		return 1;
	}

	skel->rodata->e_core_mask = emask;
	skel->rodata->nr_cpus     = nr;

	/* Pin the quarantine map at a well-known path so jeTT / scx_kage_ctl
	 * can demote PIDs into the penalty domain while we run. */
	if (bpf_map__set_pin_path(skel->maps.quarantine, QUARANTINE_PIN)) {
		fprintf(stderr, "scx_kage: set_pin_path failed: %s\n",
			strerror(errno));
		goto out_destroy;
	}

	if (scx_kage__load(skel)) {
		fprintf(stderr, "scx_kage: BPF load/verify failed: %s\n",
			strerror(errno));
		goto out_destroy;
	}

	link = bpf_map__attach_struct_ops(skel->maps.kage_ops);
	if (!link) {
		fprintf(stderr, "scx_kage: attach failed: %s "
			"(need root, a SCHED_CLASS_EXT kernel, and no other "
			"scx scheduler running)\n", strerror(errno));
		goto out_destroy;
	}

	if (emask) {
		unsigned int i, n = 0;
		for (i = 0; i < nr; i++)
			if (emask & (1ULL << i))
				n++;
		fprintf(stderr, "scx_kage: running — hybrid mode, %u E-core(s) "
			"(mask 0x%llx), quarantine map at %s\n",
			n, emask, QUARANTINE_PIN);
	} else {
		fprintf(stderr, "scx_kage: running — homogeneous mode (no "
			"E-cores detected), quarantine map at %s\n",
			QUARANTINE_PIN);
	}

	while (!exit_req) {
		fprintf(stderr, "scx_kage: normal=%llu penalty=%llu\r",
			skel->bss->nr_normal, skel->bss->nr_penalty);
		sleep(5);
	}

	fprintf(stderr, "\nscx_kage: detaching, reverting to EEVDF\n");
	bpf_link__destroy(link);
out_destroy:
	scx_kage__destroy(skel);
	return exit_req ? 0 : 1;
}
