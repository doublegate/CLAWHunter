#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import struct
import sys
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "payloads/user/reconnaissance/clawhunter/harvest.py"
# Import by path because the official Pager category directory is not a Python
# package and should not gain runtime-only __init__.py files for host tests.
SPEC = importlib.util.spec_from_file_location("clawhunter_harvest", MODULE_PATH)
harvest = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = harvest
SPEC.loader.exec_module(harvest)


class FakeSocket:
    """Small recv-only socket fixture for deterministic frame decoding tests."""

    def __init__(self, data):
        """Buffer exact fixture bytes without opening a network socket."""
        self.data = bytearray(data)

    def recv(self, count):
        """Return at most `count` buffered bytes, matching socket.recv."""
        chunk = self.data[:count]
        del self.data[:count]
        return bytes(chunk)


class HarvestTests(unittest.TestCase):
    """Unit coverage for trust boundaries and protocol primitives."""

    def test_target_validation(self):
        """Accept strict IPv4/TCP values and reject IPv6/zero-port inputs."""
        self.assertEqual(harvest.validate_target("192.0.2.1", 18789), ("192.0.2.1", 18789))
        with self.assertRaises(ValueError):
            harvest.validate_target("fe80::1", 18789)
        with self.assertRaises(ValueError):
            harvest.validate_target("192.0.2.1", 0)

    def test_websocket_frame(self):
        """Decode the normal short, unmasked server text-frame form."""
        payload = b'{"event":"connect.challenge"}'
        frame = bytes([0x81, len(payload)]) + payload
        self.assertEqual(harvest.recv_ws_frame(FakeSocket(frame)), payload)

    def test_extended_websocket_frame(self):
        """Decode the RFC 6455 16-bit extended payload-length form."""
        payload = b"x" * 126
        frame = bytes([0x81, 126]) + struct.pack("!H", len(payload)) + payload
        self.assertEqual(harvest.recv_ws_frame(FakeSocket(frame)), payload)

    def test_coalesced_partial_websocket_frame(self):
        """Preserve partial frames received with the HTTP upgrade headers."""
        payload = b'{"event":"connect.challenge"}'
        frame = bytes([0x81, len(payload)]) + payload
        self.assertEqual(
            harvest.recv_ws_frame(FakeSocket(frame[5:]), initial=frame[:5]),
            payload,
        )

    def test_discover_scheme_records_marker(self):
        """Keep transport selection separate from product marker evidence."""
        response = (200, {"x-openclaw-version": "fixture"}, b"OpenClaw Gateway")
        with mock.patch.object(harvest, "http_request", return_value=response):
            scheme, evidence = harvest.discover_scheme("192.0.2.1", 18789, harvest.Budget(10))
        self.assertEqual(scheme, "http")
        self.assertIn("root OpenClaw marker", evidence)
        self.assertIn("x-openclaw header", evidence)

    def test_tools_auth_required(self):
        """Stop the allowlisted tool sequence immediately on authentication."""
        with mock.patch.object(harvest, "json_post", return_value=(401, "denied")):
            status, results = harvest.read_only_tools(
                "http", "192.0.2.1", 18789, harvest.Budget(10), None
            )
        self.assertEqual(status, "AUTH_REQUIRED")
        self.assertEqual(results["sessions_list"]["status"], 401)

    def test_report_is_json(self):
        """Produce round-trippable deterministic JSON for Pager loot."""
        report = {"version": harvest.VERSION, "status": "ASSESSED"}
        self.assertEqual(json.loads(harvest.render_report(report)), report)


if __name__ == "__main__":
    unittest.main()
