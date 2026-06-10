import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

SENSOR_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SENSOR_DIR))

import bifrost_guardian  # noqa: E402


class SocketIPCTest(unittest.TestCase):
    def test_bifrost_receives_authenticated_json(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            socket_path = os.path.join(tmpdir, "jett_bifrost.sock")
            log_path = os.path.join(tmpdir, "jett.log")
            expected_uid = os.getuid()

            server = threading.Thread(
                target=bifrost_guardian.start_bifrost_receiver,
                kwargs={
                    "socket_path": socket_path,
                    "log_path": log_path,
                    "expected_uid": expected_uid,
                },
                daemon=True,
            )
            server.start()

            for _ in range(50):
                if os.path.exists(socket_path):
                    break
                time.sleep(0.1)
            self.assertTrue(os.path.exists(socket_path))

            payload = {
                "pid": 1234,
                "uid": expected_uid,
                "app": "bash",
                "msg": "test event",
                "verdict": "ALLOW",
            }

            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.connect(socket_path)
            client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            client.close()

            offset = 0
            log_tail = ""
            for _ in range(50):
                if os.path.exists(log_path):
                    with open(log_path, "r", encoding="utf-8") as handle:
                        handle.seek(offset)
                        chunk = handle.read()
                        offset = handle.tell()
                        log_tail += chunk
                if "Accepted jeTT client" in log_tail:
                    break
                time.sleep(0.1)

            log_contents = Path(log_path).read_text()
            self.assertIn("Accepted jeTT client", log_contents)
            self.assertIn("Application: bash", log_contents)
            self.assertIn("AI Verdict: [ALLOW]", log_contents)


if __name__ == "__main__":
    unittest.main()
