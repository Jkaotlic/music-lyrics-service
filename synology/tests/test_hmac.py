"""
Port of YandexHmac.Tests.ps1 — unit tests for HMAC signature helper.
Run: python -m unittest tests.test_hmac
"""
import sys
import os
import unittest

# Allow running from synology/ root without install
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from providers.yandex import _hmac_signature

TEST_SECRET = "test-secret-key-12345"
REAL_SECRET = "p93jhgh689SBReK6ghtw62"
TRACK_ID = "64797"
TIMESTAMP = 1745138400
# Reference vector from Task 6 (computed independently with .NET HMACSHA256):
# message = '647971745138400'  (trackId + timestamp concatenated)
EXPECTED_B64 = "GqGHjEosjMgWwTqxMiPeyu2ps8XghzpZ0cmz7EIyFuk="


class TestHmacSignature(unittest.TestCase):
    def test_deterministic_same_inputs(self):
        """Produces identical output on repeated calls with same inputs."""
        s1 = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        s2 = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        self.assertEqual(s1, s2)

    def test_valid_base64(self):
        """Output is valid base64-decodable string."""
        import base64
        s = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        # Must not raise
        decoded = base64.b64decode(s)
        self.assertIsInstance(decoded, bytes)

    def test_hmac_sha256_length(self):
        """HMAC-SHA256 is 32 bytes = 44 base64 chars (with padding)."""
        import base64
        s = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        self.assertEqual(len(s), 44)
        decoded = base64.b64decode(s)
        self.assertEqual(len(decoded), 32)

    def test_signature_changes_on_track_id(self):
        """Different trackId produces different signature."""
        s1 = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        s2 = _hmac_signature("64798", TIMESTAMP, TEST_SECRET)
        self.assertNotEqual(s1, s2)

    def test_signature_changes_on_timestamp(self):
        """Different timestamp produces different signature."""
        s1 = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        s2 = _hmac_signature(TRACK_ID, TIMESTAMP + 1, TEST_SECRET)
        self.assertNotEqual(s1, s2)

    def test_known_reference_vector(self):
        """Matches the reference vector computed with .NET HMACSHA256."""
        actual = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        self.assertEqual(actual, EXPECTED_B64)

    def test_differs_for_real_secret(self):
        """Sanity check: real Yandex secret produces different signature than test secret."""
        with_test = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        with_real = _hmac_signature(TRACK_ID, TIMESTAMP, REAL_SECRET)
        self.assertNotEqual(with_test, with_real)

    def test_message_concatenation_format(self):
        """
        Verify the message is trackId+timestamp (no separator),
        matching the PS: $Message = "$TrackId$TimeStamp"
        """
        import base64
        import hashlib
        import hmac as hmac_mod
        expected_message = f"{TRACK_ID}{TIMESTAMP}".encode("utf-8")
        key = TEST_SECRET.encode("utf-8")
        expected = base64.b64encode(hmac_mod.new(key, expected_message, hashlib.sha256).digest()).decode("ascii")
        actual = _hmac_signature(TRACK_ID, TIMESTAMP, TEST_SECRET)
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
