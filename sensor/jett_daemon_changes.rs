// jeTT eBPF Ring Buffer Reader
// Replace the /proc polling loop in src/bin/daemon.rs with this
// Requires: libbpf-rs, serde_json, lazy_static in Cargo.toml

use libbpf_rs::RingBufferBuilder;
use std::os::unix::net::UnixStream;
use std::io::Write;
use std::sync::Mutex;
use serde_json::json;

#[repr(C)]
struct KernelEvent {
    pid: u32,
    uid: u32,
    event_type: u32,
    comm: [u8; 16],
    details: [u8; 64],
}

lazy_static::lazy_static! {
    static ref BIFROST_SOCKET: Mutex<Option<UnixStream>> = Mutex::new(
        UnixStream::connect("/var/run/jett_bifrost.sock").ok()
    );
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("⚡ jeTT Daemon: Streaming live kage-ryu telemetry...");

    let mut skel_builder = libbpf_rs::SkeletonBuilder::new();
    let mut open_skel = skel_builder.open_file("/usr/lib/bpf/kage_sensor.bpf.o")?;
    let mut skel = open_skel.load()?;
    skel.attach()?;

    let maps = skel.maps();
    let ringbuf_map = maps.kage_ringbuf();

    let mut rb_builder = RingBufferBuilder::new();
    rb_builder.add(ringbuf_map, handle_kernel_event)?;
    let rb = rb_builder.build()?;

    loop {
        rb.poll(std::time::Duration::from_millis(10))?;
    }
}

fn handle_kernel_event(data: &[u8]) -> i32 {
    if data.len() < std::mem::size_of::<KernelEvent>() { return 0; }

    let raw_event = unsafe { &*(data.as_ptr() as *const KernelEvent) };
    let comm = String::from_utf8_lossy(&raw_event.comm).trim_matches('\0').to_string();
    let details = String::from_utf8_lossy(&raw_event.details).trim_matches('\0').to_string();

    let verdict = evaluate_ai_verdict(raw_event.event_type, &comm, &details);

    if verdict == "QUARANTINE" {
        println!("🚨 jeTT QUARANTINE: {} (PID: {})", comm, raw_event.pid);
    }

    if let Some(ref mut stream) = *BIFROST_SOCKET.lock().unwrap() {
        let payload = json!({
            "pid": raw_event.pid,
            "uid": raw_event.uid,
            "app": comm,
            "type": raw_event.event_type,
            "msg": details,
            "verdict": verdict
        }).to_string() + "\n";
        let _ = stream.write_all(payload.as_bytes());
    }
    0
}

fn evaluate_ai_verdict(event_type: u32, comm: &str, details: &str) -> &'static str {
    // Connect to existing jeTT AI inference here
    if details.contains("/etc/shadow") || details.contains("/tmp/.") {
        return "QUARANTINE";
    }
    "ALLOW"
}
