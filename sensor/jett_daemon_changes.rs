// jeTT eBPF Ring Buffer Reader
// Replace the /proc polling loop in src/bin/daemon.rs with this
// Requires: libbpf-rs, libbpf-sys, serde_json, lazy_static in Cargo.toml

use libbpf_rs::RingBufferBuilder;
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex,
};

// ── Shared data layout (must match kage_sensor.bpf.c:event_t) ───────────────
#[repr(C)]
struct KernelEvent {
    pid: u32,
    uid: u32,
    event_type: u32,
    comm: [u8; 16],
    details: [u8; 64],
}

lazy_static::lazy_static! {
    /// Unix socket connection to the Bifrost Guardian dashboard process.
    static ref BIFROST_SOCKET: Mutex<Option<UnixStream>> = Mutex::new(
        UnixStream::connect("/var/run/jett_bifrost.sock").ok()
    );

    /// File descriptor of the eBPF `quarantine_map` (BPF_MAP_TYPE_HASH, u32→u32).
    ///
    /// Populated in `main()` once the BPF skeleton is loaded.  The ring-buffer
    /// callback uses it to write a quarantined PID directly into the kernel map
    /// so that `kage_enforce_quarantine` (lsm/bprm_check_security) blocks any
    /// subsequent `execve()` from that process.
    static ref QUARANTINE_MAP_FD: Mutex<Option<i32>> = Mutex::new(None);
}

static EVENT_TOTAL: AtomicU64 = AtomicU64::new(0);
static QUARANTINE_TOTAL: AtomicU64 = AtomicU64::new(0);
static LAST_EVENT_TS: AtomicU64 = AtomicU64::new(0);

// ── Entry point ───────────────────────────────────────────────────────────────
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("⚡ jeTT Daemon: Streaming live kage-ryu telemetry…");
    std::thread::spawn(start_metrics_server);

    // ── Try to load the eBPF skeleton ─────────────────────────────────────────
    match try_ebpf_mode() {
        Ok(()) => {}
        Err(e) => {
            eprintln!(
                "⚠️  jeTT FALLBACK MODE: eBPF ring buffer unavailable ({e}).\n\
                 ⚠️  Switching to /proc polling — higher overhead, reduced visibility.\n\
                 ⚠️  Resolve eBPF setup (BTF kernel, kage-sensor.service) for full protection."
            );
            run_proc_fallback()?;
        }
    }
    Ok(())
}

// ── Normal (eBPF) mode ────────────────────────────────────────────────────────
fn try_ebpf_mode() -> Result<(), Box<dyn std::error::Error>> {
    let mut skel_builder = libbpf_rs::SkeletonBuilder::new();
    let mut open_skel = skel_builder.open_file("/usr/lib/bpf/kage_sensor.bpf.o")?;
    let mut skel = open_skel.load()?;
    skel.attach()?;

    let maps = skel.maps();

    // Store the quarantine_map fd for use in the ring-buffer callback.
    // SAFETY: The fd is valid for the lifetime of `skel`, which is kept alive
    // for the entire duration of the polling loop below.
    *QUARANTINE_MAP_FD.lock().unwrap() = Some(maps.quarantine_map().fd());

    let ringbuf_map = maps.kage_ringbuf();

    let mut rb_builder = RingBufferBuilder::new();
    rb_builder.add(ringbuf_map, handle_kernel_event)?;
    let rb = rb_builder.build()?;

    loop {
        rb.poll(std::time::Duration::from_millis(10))?;
    }
}

// ── Ring-buffer event handler ─────────────────────────────────────────────────
fn handle_kernel_event(data: &[u8]) -> i32 {
    if data.len() < std::mem::size_of::<KernelEvent>() {
        return 0;
    }

    // SAFETY: `data` is a kernel-provided buffer whose layout matches
    // `struct event_t` in kage_sensor.bpf.c.  The length check above
    // guarantees the slice is at least as large as `KernelEvent`.
    let raw_event = unsafe { &*(data.as_ptr() as *const KernelEvent) };
    let comm = String::from_utf8_lossy(&raw_event.comm)
        .trim_matches('\0')
        .to_string();
    let details = String::from_utf8_lossy(&raw_event.details)
        .trim_matches('\0')
        .to_string();

    let verdict = evaluate_ai_verdict(raw_event.event_type, &comm, &details);
    record_metrics(verdict);

    if verdict == "QUARANTINE" {
        println!("🚨 jeTT QUARANTINE: {} (PID: {})", comm, raw_event.pid);
        // Write PID into the kernel quarantine_map so that the LSM hook
        // (`kage_enforce_quarantine`) blocks any further execve() from this PID.
        enforce_quarantine_in_map(raw_event.pid);
    }

    send_to_bifrost(
        raw_event.pid,
        raw_event.uid,
        &comm,
        raw_event.event_type,
        &details,
        verdict,
    );
    0
}

/// Insert `pid` into the eBPF `quarantine_map` so the kernel LSM hook can
/// block the process from executing new binaries.
///
/// # Safety assumptions
/// - `QUARANTINE_MAP_FD` holds a valid BPF map fd opened with `BPF_MAP_TYPE_HASH`,
///   `key_size = 4`, `value_size = 4`.
/// - The fd remains valid for the duration of the daemon's lifetime.
/// - A failed update is logged and silently ignored (best-effort enforcement);
///   Bifrost still receives the QUARANTINE verdict for out-of-band action.
fn enforce_quarantine_in_map(pid: u32) {
    let guard = QUARANTINE_MAP_FD.lock().unwrap();
    if let Some(fd) = *guard {
        let value: u32 = 1u32;
        // SAFETY: We pass valid pointers to 4-byte values matching the map's
        // declared key_size/value_size, and BPF_ANY (0) as the update flag.
        let ret = unsafe {
            libbpf_sys::bpf_map_update_elem(
                fd,
                &pid as *const u32 as *const libbpf_sys::c_void,
                &value as *const u32 as *const libbpf_sys::c_void,
                libbpf_sys::BPF_ANY as u64,
            )
        };
        if ret != 0 {
            eprintln!(
                "⚠️  jeTT: bpf_map_update_elem failed for PID {} (errno {})",
                pid, ret
            );
        }
    } else {
        eprintln!(
            "⚠️  jeTT: quarantine_map fd not available; cannot enforce PID {} in kernel.",
            pid
        );
    }
}

// ── Fallback: /proc polling ───────────────────────────────────────────────────
/// Poll `/proc` for new processes when the eBPF ring buffer is unavailable.
///
/// Limitations compared to the eBPF path:
/// - ~250 ms latency between process creation and detection.
/// - No file-open or network-connect visibility; only new PID detection.
/// - QUARANTINE enforcement is best-effort via SIGKILL (no kernel map available).
fn run_proc_fallback() -> Result<(), Box<dyn std::error::Error>> {
    let mut known_pids: HashMap<u32, ()> = HashMap::new();

    loop {
        if let Ok(entries) = fs::read_dir("/proc") {
            let mut current_pids: HashMap<u32, ()> = HashMap::new();

            for entry in entries.flatten() {
                let fname = entry.file_name();
                let name = fname.to_string_lossy();
                if let Ok(pid) = name.parse::<u32>() {
                    current_pids.insert(pid, ());

                    if !known_pids.contains_key(&pid) {
                        // New process — evaluate it
                        let comm = fs::read_to_string(format!("/proc/{pid}/comm"))
                            .unwrap_or_default()
                            .trim()
                            .to_string();
                        let cmdline = fs::read_to_string(format!("/proc/{pid}/cmdline"))
                            .unwrap_or_default()
                            .replace('\0', " ")
                            .trim()
                            .to_string();

                        let verdict = evaluate_ai_verdict(1, &comm, &cmdline);
                        record_metrics(verdict);

                        if verdict == "QUARANTINE" {
                            eprintln!(
                                "🚨 jeTT FALLBACK QUARANTINE: {} (PID: {}) — sending SIGKILL",
                                comm, pid
                            );
                            // Best-effort: signal the process.
                            // We use `kill -9` via the shell to avoid a libc dependency.
                            // Assumption: process may have already exited; the shell call
                            // failing is non-fatal.
                            let _ = std::process::Command::new("kill")
                                .args(["-9", &pid.to_string()])
                                .status();
                        }

                        send_to_bifrost(pid, 0, &comm, 1, &cmdline, verdict);
                    }
                }
            }

            known_pids = current_pids;
        }

        std::thread::sleep(std::time::Duration::from_millis(250));
    }
}

// ── Shared helpers ────────────────────────────────────────────────────────────

/// Forward an event to the Bifrost Guardian over the Unix socket.
fn send_to_bifrost(pid: u32, uid: u32, app: &str, event_type: u32, msg: &str, verdict: &str) {
    if let Some(ref mut stream) = *BIFROST_SOCKET.lock().unwrap() {
        let payload = json!({
            "pid":     pid,
            "uid":     uid,
            "app":     app,
            "type":    event_type,
            "msg":     msg,
            "verdict": verdict
        })
        .to_string()
            + "\n";
        let _ = stream.write_all(payload.as_bytes());
    }
}

/// Heuristic threat-scoring function.
///
/// Replace / extend with the real jeTT AI inference engine as appropriate.
fn evaluate_ai_verdict(_event_type: u32, _comm: &str, details: &str) -> &'static str {
    if details.contains("/etc/shadow") || details.contains("/tmp/.") {
        return "QUARANTINE";
    }
    "ALLOW"
}

fn record_metrics(verdict: &str) {
    EVENT_TOTAL.fetch_add(1, Ordering::Relaxed);
    LAST_EVENT_TS.store(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or(0),
        Ordering::Relaxed,
    );

    if verdict == "QUARANTINE" {
        QUARANTINE_TOTAL.fetch_add(1, Ordering::Relaxed);
    }
}

fn start_metrics_server() {
    let listener = match TcpListener::bind("127.0.0.1:9101") {
        Ok(listener) => listener,
        Err(err) => {
            eprintln!("⚠️  jeTT metrics server unavailable: {}", err);
            return;
        }
    };

    for mut stream in listener.incoming().flatten() {
        let mut request = [0u8; 1024];
        let read = stream.read(&mut request).unwrap_or(0);
        let request_line = String::from_utf8_lossy(&request[..read])
            .lines()
            .next()
            .unwrap_or("");
        let path = request_line.split_whitespace().nth(1).unwrap_or("/");

        if path == "/metrics" {
            let body = render_metrics();
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(response.as_bytes());
        } else {
            let body = "not found\n";
            let response = format!(
                "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(response.as_bytes());
        }
    }
}

fn render_metrics() -> String {
    format!(
        concat!(
            "# HELP jett_events_total Total jeTT events processed\n",
            "# TYPE jett_events_total counter\n",
            "jett_events_total {}\n",
            "# HELP jett_quarantine_total Total quarantine verdicts\n",
            "# TYPE jett_quarantine_total counter\n",
            "jett_quarantine_total {}\n",
            "# HELP jett_last_event_timestamp_seconds Timestamp of the most recent event\n",
            "# TYPE jett_last_event_timestamp_seconds gauge\n",
            "jett_last_event_timestamp_seconds {}\n"
        ),
        EVENT_TOTAL.load(Ordering::Relaxed),
        QUARANTINE_TOTAL.load(Ordering::Relaxed),
        LAST_EVENT_TS.load(Ordering::Relaxed),
    )
}

#[cfg(test)]
mod tests {
    use super::evaluate_ai_verdict;

    #[test]
    fn allows_benign_events() {
        assert_eq!(evaluate_ai_verdict(1, "bash", "/usr/bin/ls"), "ALLOW");
    }

    #[test]
    fn quarantines_sensitive_paths() {
        assert_eq!(evaluate_ai_verdict(1, "cat", "/etc/shadow"), "QUARANTINE");
        assert_eq!(
            evaluate_ai_verdict(1, "python", "/tmp/.ssh/id_rsa"),
            "QUARANTINE"
        );
    }
}
