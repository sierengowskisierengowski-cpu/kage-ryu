# Kage-Ryu Sensor Stack — `sensor/` Folder

## What is this?

The `sensor/` folder contains the kernel-space and user-space components of the
**Kage-Ryu security sensor stack** — a real-time, eBPF-powered threat detection
and enforcement pipeline built for Arch Linux.

---

## Components

| File / Directory | Role |
|---|---|
| `kage_sensor.bpf.c` | eBPF kernel program: hooks execve, openat, connect, setuid; submits events via ring buffer; enforces quarantine via LSM |
| `jett_daemon_changes.rs` | User-space daemon (jeTT): reads eBPF ring buffer, scores events, enforces quarantine in kernel map, streams verdicts to Bifrost |
| `bifrost_guardian.py` | Bifrost: Unix-socket server that receives jeTT verdicts, displays dashboard, sends push notifications on QUARANTINE |
| `Cargo.toml` | Rust dependencies for jeTT daemon |
| `install.sh` | One-shot installer: compiles eBPF program, installs all components, enables systemd services |
| `systemd/kage-sensor.service` | Loads the compiled BPF object and pins programs via bpftool |
| `systemd/bifrost-guardian.service` | Starts Bifrost socket server, waits for socket readiness before jeTT starts |
| `systemd/jett.service` | Starts jeTT daemon (depends on kage-sensor + bifrost-guardian) |
| `kage-status` | Operator health-check script |
| `logrotate.conf` | Log rotation for `/var/log/jett/jett.log` |

---

## Full Stack — End-to-End Flow

```
┌──────────────────────────────────────────────────────────────┐
│  Kernel Space                                                │
│                                                              │
│  kage_sensor.bpf.c                                          │
│  ├─ tp/execve    ─────┐                                     │
│  ├─ tp/openat    ─────┤──► kage_ringbuf (BPF ring buffer)  │
│  ├─ tp/connect   ─────┘                                     │
│  ├─ tp/setuid    ─────► kage_ringbuf                        │
│  └─ lsm/bprm_check ──► quarantine_map lookup → block exec  │
└────────────────────────┬─────────────────────────────────────┘
                         │ ring buffer events
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  User Space — jeTT daemon (jett_daemon_changes.rs)          │
│                                                              │
│  1. Poll kage_ringbuf for new events                        │
│  2. evaluate_ai_verdict() → ALLOW or QUARANTINE             │
│  3. If QUARANTINE:                                          │
│       • bpf_map_update_elem(quarantine_map, pid, 1)         │
│         (kernel LSM will block next execve from this PID)   │
│       • Log to stdout / journald                            │
│  4. Forward JSON event to Bifrost via Unix socket           │
│                                                              │
│  Fallback (if eBPF unavailable):                            │
│       • Poll /proc every 250 ms for new PIDs                │
│       • QUARANTINE → SIGKILL (best-effort)                  │
└─────────────────────────────┬────────────────────────────────┘
                              │ JSON over /var/run/jett_bifrost.sock
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Bifrost Guardian (bifrost_guardian.py)                     │
│                                                              │
│  • Renders security dashboard in terminal                   │
│  • Sends push notifications (Pushover / NTFY) on QUARANTINE │
└──────────────────────────────────────────────────────────────┘
```

---

## Installation

### Prerequisites

```bash
# Arch Linux
sudo pacman -S bpf clang llvm libbpf python3
# Rust (for jeTT build from source)
curl https://sh.rustup.rs -sSf | sh
```

Your kernel **must** have been built with:
- `CONFIG_DEBUG_INFO_BTF=y`  (for vmlinux.h generation)
- `CONFIG_BPF_LSM=y`         (for quarantine enforcement)
- `CONFIG_BPF_SYSCALL=y`

The linux-kage-ryu PKGBUILD ships all of these enabled by default.

### One-shot install

```bash
git clone https://github.com/sierengowskisierengowski-cpu/kage-ryu.git
cd kage-ryu
sudo bash sensor/install.sh
```

`install.sh` will:

1. Generate `vmlinux.h` from the running kernel's BTF blob
2. Compile `kage_sensor.bpf.c` → `kage_sensor.bpf.o`
3. Copy the BPF object to `/usr/lib/bpf/`
4. Install Bifrost to `/usr/lib/bifrost/`
5. Build (or install) the jeTT daemon to `/usr/bin/jett_daemon`
6. Install and enable systemd services in the correct order

### Manual service management

```bash
# Check status
systemctl status kage-sensor bifrost-guardian jett

# View live events
journalctl -u jett -f

# Quick health check
bash sensor/kage-status
```

---

## Operational Notes

- **QUARANTINE** events are enforced in two layers:
  1. jeTT writes the PID into the kernel `quarantine_map` → any subsequent
     `execve()` from that PID returns `-EPERM`.
  2. Bifrost can trigger out-of-band notifications (phone push, webhook).
- **Fallback mode** activates automatically if the eBPF ring buffer fails to
  load (e.g., missing BTF, wrong kernel).  Performance is degraded (~250 ms
  detection latency vs. near-zero in eBPF mode); check `journalctl -u jett`.
- Log files are rotated weekly by `/etc/logrotate.d/jett`.

---

## Directory Layout

```
sensor/
├── install.sh                  ← installer (run as root)
├── kage_sensor.bpf.c           ← eBPF kernel program
├── jett_daemon_changes.rs      ← jeTT user-space daemon source
├── bifrost_guardian.py         ← Bifrost dashboard daemon
├── Cargo.toml                  ← Rust manifest for jeTT
├── kage-status                 ← operator health-check script
├── logrotate.conf              ← log rotation config
├── README.md                   ← this file
└── systemd/
    ├── kage-sensor.service
    ├── bifrost-guardian.service
    └── jett.service
```
