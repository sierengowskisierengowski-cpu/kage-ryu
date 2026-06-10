import json
import logging
from logging.handlers import WatchedFileHandler
import os
import socket
import struct
import threading

SOCKET_PATH = "/var/run/jett_bifrost.sock"
LOG_PATH = "/var/log/jett/jett.log"
EXPECTED_UID = int(os.environ.get("JETT_BIFROST_UID", "0"))


def setup_logger(log_path=LOG_PATH):
    logger = logging.getLogger("bifrost")
    if logger.handlers:
        return logger

    logger.setLevel(logging.INFO)
    logger.propagate = False

    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)

    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    file_handler = WatchedFileHandler(log_path)
    file_handler.setFormatter(formatter)

    logger.addHandler(stream_handler)
    logger.addHandler(file_handler)
    return logger


def extract_credentials(ancdata):
    for level, ctype, data in ancdata:
        if level == socket.SOL_SOCKET and ctype == socket.SCM_CREDENTIALS:
            return struct.unpack("3i", data[:12])
    return None


def start_bifrost_receiver(socket_path=SOCKET_PATH, log_path=LOG_PATH, expected_uid=EXPECTED_UID):
    logger = setup_logger(log_path)

    if os.path.exists(socket_path):
        os.remove(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
    server.bind(socket_path)
    os.chmod(socket_path, 0o660)
    server.listen(5)

    logger.info("Bifrost ready on %s", socket_path)

    while True:
        conn, _ = server.accept()
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
        threading.Thread(
            target=handle_jett_connection,
            args=(conn, logger, expected_uid),
            daemon=True,
        ).start()


def handle_jett_connection(conn, logger, expected_uid):
    buffer = ""
    authenticated = False
    try:
        while True:
            data, ancdata, *_ = conn.recvmsg(4096, socket.CMSG_SPACE(struct.calcsize("3i")))
            if not data:
                break
            if not authenticated:
                credentials = extract_credentials(ancdata)
                if credentials is None:
                    logger.warning("Rejected socket client without SCM_CREDENTIALS")
                    break
                pid, uid, gid = credentials
                if uid != expected_uid:
                    logger.warning(
                        "Rejected socket client pid=%s uid=%s gid=%s (expected uid %s)",
                        pid,
                        uid,
                        gid,
                        expected_uid,
                    )
                    break
                authenticated = True
                logger.info("Accepted jeTT client pid=%s uid=%s gid=%s", pid, uid, gid)

            buffer += data.decode("utf-8", errors="replace")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                if line.strip():
                    try:
                        event_packet = json.loads(line)
                    except json.JSONDecodeError as exc:
                        logger.warning("Dropping malformed event packet: %s", exc)
                        continue
                    update_dashboard_ui(event_packet, logger)
    except Exception as exc:
        logger.warning("Socket stream exception: %s", exc)
    finally:
        conn.close()


def update_dashboard_ui(packet, logger):
    logger.info("==============================================")
    logger.info("BIFROST SECURITY UPDATE")
    logger.info("Application: %s (PID: %s)", packet.get("app"), packet.get("pid"))
    logger.info("Activity: %s", packet.get("msg"))
    logger.info("AI Verdict: [%s]", packet.get("verdict"))
    logger.info("==============================================")

    if packet.get("verdict") == "QUARANTINE":
        send_push_notification(packet, logger)


def send_push_notification(packet, logger):
    logger.warning("Push notification requested for %s", packet.get("app"))


if __name__ == "__main__":
    start_bifrost_receiver()
