#include <vmlinux.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

struct event_t {
    u32 pid;
    u32 uid;
    u32 event_type;
    char comm[16];
    char details[64];
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 16);
} kage_ringbuf SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);
    __type(value, u32);
} quarantine_map SEC(".maps");

static __always_inline void submit_event(void *ctx, u32 type, const char *details) {
    struct event_t *e = bpf_ringbuf_reserve(&kage_ringbuf, sizeof(*e), 0);
    if (!e) return;
    e->pid = bpf_get_current_pid_tgid() >> 32;
    e->uid = bpf_get_current_uid_gid();
    e->event_type = type;
    bpf_get_current_comm(&e->comm, sizeof(e->comm));
    bpf_probe_read_kernel_str(&e->details, sizeof(e->details), details);
    bpf_ringbuf_submit(e, 0);
}

SEC("tp/syscalls/sys_enter_execve")
int kage_execve(struct trace_event_raw_sys_enter *ctx) {
    const char *filename = (const char *)BPF_CORE_READ(ctx, args[0]);
    submit_event(ctx, 1, filename);
    return 0;
}

SEC("tp/syscalls/sys_enter_openat")
int kage_file_open(struct trace_event_raw_sys_enter *ctx) {
    const char *filename = (const char *)BPF_CORE_READ(ctx, args[1]);
    submit_event(ctx, 2, filename);
    return 0;
}

SEC("tp/syscalls/sys_enter_connect")
int kage_network_connect(struct trace_event_raw_sys_enter *ctx) {
    submit_event(ctx, 3, "Outbound connection initiated");
    return 0;
}

SEC("tp/syscalls/sys_enter_setuid")
int kage_priv_esc(struct trace_event_raw_sys_enter *ctx) {
    uid_t target_uid = (uid_t)BPF_CORE_READ(ctx, args[0]);
    if (target_uid == 0) {
        submit_event(ctx, 4, "Attempted root elevation");
    }
    return 0;
}

SEC("lsm/bprm_check_security")
int BPF_PROG(kage_enforce_quarantine, struct linux_binprm *bprm) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u32 *blocked = bpf_map_lookup_elem(&quarantine_map, &pid);
    if (blocked) {
        submit_event(bprm, 1, "QUARANTINE ENFORCED - Execution Blocked");
        return -EPERM;
    }
    return 0;
}
