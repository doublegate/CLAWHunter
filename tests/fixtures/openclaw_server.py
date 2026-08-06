#!/usr/bin/env python3
"""Local HTTP/WebSocket fixture for CLAWHunter integration checks.

This server implements only the current protocol surfaces exercised by the
release gate. It never binds beyond loopback and accepts one fixed test token.
"""

import argparse
import base64
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# RFC 6455's fixed GUID is combined with each request key for upgrade validation.
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class FixtureHandler(BaseHTTPRequestHandler):
    """Serve deterministic root, health, challenge, and tool responses."""

    server_version = "OpenClawFixture/3.3.0"

    def log_message(self, _format, *_args):
        """Keep test output quiet unless an assertion fails."""

    def _json(self, status, payload):
        """Send one bounded JSON response carrying an OpenClaw marker header."""
        body = json.dumps(payload, separators=(",", ":")).encode("ascii")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-OpenClaw-Version", "fixture")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        """Return health data or a valid challenge-bearing WS upgrade."""
        if self.headers.get("Upgrade", "").lower() == "websocket":
            # Mirror the current gateway sequence: validate the client key via
            # Sec-WebSocket-Accept, then send connect.challenge as a text frame.
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            # The short payload fits the single-byte frame length used here.
            payload = b'{"event":"connect.challenge","payload":{"nonce":"fixture"}}'
            self.wfile.write(bytes([0x81, len(payload)]) + payload)
            self.wfile.flush()
            return
        # Route bodies intentionally distinguish product-specific liveness from
        # generic readiness, matching the classifier's different evidence weight.
        if self.path == "/healthz":
            self._json(200, {"ok": True, "service": "OpenClaw"})
        elif self.path == "/readyz":
            self._json(200, {"ok": True, "status": "ready"})
        elif self.path.startswith("/__openclaw__/canvas/"):
            self._json(404, {"error": "disabled"})
        else:
            self._json(200, {"name": "OpenClaw Gateway", "fixture": True})

    def do_POST(self):
        """Require the fixed token and return read-only tool fixture data."""
        # Requests are produced by the bounded client and remain small. Reading
        # exactly Content-Length also leaves the HTTP connection deterministic.
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        # The fixture recognizes only the two tools hard-coded in harvest.py;
        # any accidental allowlist expansion fails deterministically with 404.
        if self.path != "/tools/invoke":
            self._json(404, {"ok": False})
        elif self.headers.get("Authorization") != "Bearer fixture-token":
            self._json(401, {"ok": False, "error": "auth required"})
        elif request.get("tool") == "sessions_list":
            self._json(200, {"ok": True, "sessions": []})
        elif request.get("tool") == "memory_search":
            self._json(200, {"ok": True, "results": []})
        else:
            self._json(404, {"ok": False, "error": "tool unavailable"})


def main():
    """Bind an ephemeral loopback port, publish it, and serve until killed."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    # Port zero delegates collision-free selection to the kernel; the explicit
    # loopback address prevents the fixture from becoming LAN-reachable.
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    Path(args.port_file).write_text(str(server.server_port), encoding="ascii")
    server.serve_forever()


if __name__ == "__main__":
    main()
