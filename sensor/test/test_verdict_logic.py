import unittest


def evaluate_ai_verdict(details: str) -> str:
    if "/etc/shadow" in details or "/tmp/." in details:
        return "QUARANTINE"
    return "ALLOW"


class VerdictLogicTest(unittest.TestCase):
    def test_allows_benign_paths(self):
        self.assertEqual(evaluate_ai_verdict("/usr/bin/ls"), "ALLOW")

    def test_quarantines_sensitive_paths(self):
        self.assertEqual(evaluate_ai_verdict("/etc/shadow"), "QUARANTINE")
        self.assertEqual(evaluate_ai_verdict("/tmp/.ssh/id_rsa"), "QUARANTINE")


if __name__ == "__main__":
    unittest.main()
