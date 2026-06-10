import os
import socket
import json
import threading

SOCKET_PATH = "/var/run/jett_bifrost.sock"

def start_bifrost_receiver():
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(5)

    print(f"🛡️ Bifrost Core: Operational. Listening for jeTT verdicts on {SOCKET_PATH}...")

    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle_jett_connection, args=(conn,), daemon=True).start()

def handle_jett_connection(conn):
    buffer = ""
    try:
        while True:
            data = conn.recv(4096).decode('utf-8')
            if not data:
                break
            buffer += data
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                if line.strip():
                    event_packet = json.loads(line)
                    update_dashboard_ui(event_packet)
    except Exception as e:
        print(f"⚠️ Socket Stream Exception: {e}")
    finally:
        conn.close()

def update_dashboard_ui(packet):
    print(f"\n==============================================")
    print(f"📊 BIFROST SECURITY UPDATE")
    print(f"Application: {packet['app']} (PID: {packet['pid']})")
    print(f"Activity:    {packet['msg']}")
    print(f"AI Verdict:  [{packet['verdict']}]")
    print(f"==============================================")

    if packet['verdict'] == "QUARANTINE":
        send_push_notification(packet)

def send_push_notification(packet):
    # Hook phone notifications here (Pushover, NTFY, Twilio)
    pass

if __name__ == "__main__":
    start_bifrost_receiver()
