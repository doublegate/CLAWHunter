#!/usr/bin/env python3
"""Bounded, current-protocol OpenClaw assessment for CLAWHunter.

The Pager calls this module only after a confirmed discovery. It records public
HTTP and WebSocket evidence and, when the operator supplied an authorized
gateway secret, invokes a deliberately small read-only tool set. The module has
no third-party dependencies, never sends agent prompts or shell commands, and
returns partial reports when its global time budget expires.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import ipaddress
import json
import os
import socket
import ssl
import struct
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# VERSION must match common.sh and all three Pager entry points.
VERSION = "3.3.0"
# Hard upper bound across discovery, health, WebSocket, tools, and report work.
GLOBAL_CEILING = 180
# Per-response memory ceiling; report fields apply smaller readability caps.
MAX_BODY = 65536


@dataclass
class Budget:
    """One monotonic deadline shared by every network phase.

    Per-operation caps prevent one socket from consuming the full run while the
    shared start time guarantees retries and optional phases cannot extend the
    operator-selected timeout or the 180-second global ceiling.
    """

    seconds: int

    def __post_init__(self) -> None:
        """Capture the shared deadline origin immediately after construction."""
        # monotonic time is immune to NTP/manual clock changes during a scan.
        self.started = time.monotonic()

    def remaining(self, cap: float = 8.0) -> float:
        """Return a positive socket timeout bounded by `cap` and the deadline."""
        left = self.seconds - (time.monotonic() - self.started)
        if left <= 0:
            raise TimeoutError("global harvest budget exhausted")
        return max(0.1, min(cap, left))


def validate_target(ip: str, port: int) -> tuple[str, int]:
    """Normalize an IPv4 target and reject values unsafe for network clients."""
    parsed = ipaddress.ip_address(ip)
    if parsed.version != 4:
        raise ValueError("only IPv4 targets are supported")
    if not 1 <= port <= 65535:
        raise ValueError("port must be between 1 and 65535")
    return str(parsed), port


def _connection(scheme: str, ip: str, port: int, timeout: float):
    """Create a bounded HTTP connection for a discovered transport scheme.

    LAN gateways commonly use self-signed TLS. Certificate verification is
    disabled for evidence collection only; no server identity trust is implied.
    """
    if scheme == "https":
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        return http.client.HTTPSConnection(ip, port, timeout=timeout, context=context)
    return http.client.HTTPConnection(ip, port, timeout=timeout)


def http_request(
    scheme: str,
    ip: str,
    port: int,
    method: str,
    path: str,
    budget: Budget,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    """Issue one request and return normalized headers plus a capped body."""
    # Connection: close avoids idle keep-alive sockets accumulating across the
    # constrained Pager process and makes each phase's timeout ownership clear.
    request_headers = {"User-Agent": f"CLAWHunter/{VERSION}", "Connection": "close"}
    if headers:
        request_headers.update(headers)
    conn = _connection(scheme, ip, port, budget.remaining())
    try:
        conn.request(method, path, body=body, headers=request_headers)
        response = conn.getresponse()
        # Read one byte beyond the ceiling and truncate. The caller needs bounded
        # evidence, not an unbounded UI/document download from the gateway root.
        payload = response.read(MAX_BODY + 1)[:MAX_BODY]
        return response.status, {k.lower(): v for k, v in response.getheaders()}, payload
    finally:
        conn.close()


def discover_scheme(ip: str, port: int, budget: Budget) -> tuple[str | None, list[str]]:
    """Select HTTP or HTTPS and retain the root response evidence.

    Any HTTP status establishes a usable transport, but marker/header evidence
    is recorded separately so callers do not confuse reachability with product
    identification.
    """
    evidence: list[str] = []
    # HTTP comes first because a successful cleartext transport also supports
    # direct RFC 6455 challenge capture without implementing TLS framing here.
    for scheme in ("http", "https"):
        try:
            status, headers, body = http_request(scheme, ip, port, "GET", "/", budget)
        except (OSError, http.client.HTTPException, ssl.SSLError):
            continue
        evidence.append(f"root={status} ({scheme})")
        lowered = body.lower()
        if b"openclaw" in lowered or b"clawd" in lowered:
            evidence.append("root OpenClaw marker")
        if any(name.startswith("x-openclaw") for name in headers):
            evidence.append("x-openclaw header")
        return scheme, evidence
    return None, evidence


def _recv_exact(sock: socket.socket, count: int) -> bytes:
    """Read exactly `count` bytes or fail on an early WebSocket close."""
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("WebSocket closed")
        data.extend(chunk)
    return bytes(data)


def recv_ws_frame(sock: socket.socket, initial: bytes = b"") -> bytes:
    """Decode one bounded RFC 6455 frame from a server or fixture socket.

    Server frames are normally unmasked, but masked frames are accepted for
    resilient diagnostics. Payloads above MAX_BODY are truncated deliberately
    to protect Pager memory; challenge frames are far below that bound. `initial`
    preserves frame bytes coalesced with the HTTP upgrade response, including a
    partially received frame header or payload.
    """
    buffered = bytearray(initial)

    def take(count: int) -> bytes:
        """Return exactly `count` bytes from buffered and then socket data."""
        # Consume coalesced bytes before reading the socket. This is essential
        # when the 101 response and only part of the first frame share a packet.
        while len(buffered) < count:
            buffered.extend(_recv_exact(sock, count - len(buffered)))
        data = bytes(buffered[:count])
        del buffered[:count]
        return data

    first, second = take(2)
    # RFC 6455 uses 7, 16, or 64-bit payload lengths in the frame prefix.
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", take(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", take(8))[0]
    masked = bool(second & 0x80)
    mask = take(4) if masked else b""
    payload = bytearray(take(min(length, MAX_BODY)))
    if masked:
        # Servers normally do not mask frames; supporting it keeps diagnostics
        # deterministic for fixtures and non-conforming intermediary behavior.
        for index in range(len(payload)):
            payload[index] ^= mask[index % 4]
    if (first & 0x0F) == 0x8:
        return b""
    return bytes(payload)


def websocket_challenge(ip: str, port: int, budget: Budget) -> tuple[str, dict[str, Any] | None]:
    """Validate the WebSocket upgrade and capture the first gateway event.

    A proper Sec-WebSocket-Accept is required before parsing data. OpenClaw's
    connect.challenge proves the current protocol listener is present, but this
    assessment does not forge a device identity or attempt pairing. Some
    servers coalesce the first frame with HTTP headers, so the parser handles
    both coalesced and subsequent-frame delivery.
    """
    # A fresh nonce lets Sec-WebSocket-Accept validation prove this response was
    # generated for the current connection rather than matching a static banner.
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        "GET / HTTP/1.1\r\n"
        f"Host: {ip}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Origin: http://{ip}:{port}\r\n\r\n"
    ).encode("ascii")
    sock = socket.create_connection((ip, port), timeout=budget.remaining(4))
    try:
        sock.settimeout(budget.remaining(4))
        sock.sendall(request)
        response = bytearray()
        # Bound headers independently from the frame/body ceiling. A gateway
        # emitting more than 16 KiB before header termination is not usable here.
        while b"\r\n\r\n" not in response and len(response) < 16384:
            response.extend(sock.recv(2048))
        header, _, trailing = bytes(response).partition(b"\r\n\r\n")
        if b" 101 " not in header.split(b"\r\n", 1)[0]:
            return "REJECTED", None
        # RFC 6455 requires SHA-1(key + GUID). A 101 without this exact value is
        # a generic/malformed response and cannot establish WebSocket evidence.
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        )
        if accept.lower() not in header.lower():
            return "INVALID_UPGRADE", None
        payload = recv_ws_frame(sock, trailing)
        try:
            message = json.loads(payload.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            return "UPGRADED", None
        if message.get("event") == "connect.challenge":
            return "CHALLENGE_REQUIRED", message
        return "UPGRADED", message
    finally:
        sock.close()


def json_post(
    scheme: str,
    ip: str,
    port: int,
    path: str,
    payload: dict[str, Any],
    budget: Budget,
    token: str | None,
) -> tuple[int, dict[str, Any] | str]:
    """POST compact JSON with optional bearer auth and bounded response text."""
    headers = {"Content-Type": "application/json"}
    if token:
        # The value is inserted only into the in-memory request header and is
        # never returned in the response/report structure.
        headers["Authorization"] = f"Bearer {token}"
    status, _, body = http_request(
        scheme, ip, port, "POST", path, budget,
        json.dumps(payload, separators=(",", ":")).encode(), headers,
    )
    text = body.decode("utf-8", errors="replace")
    try:
        return status, json.loads(text)
    except json.JSONDecodeError:
        return status, text[:4096]


def read_only_tools(
    scheme: str, ip: str, port: int, budget: Budget, token: str | None
) -> tuple[str, dict[str, Any]]:
    """Invoke only the two explicitly approved read-only assessment tools.

    `/tools/invoke` treats a shared token/password as full operator authority.
    Keeping this allowlist local and literal prevents target responses or CLI
    input from selecting mutating tools. Policy denials are recorded, not
    bypassed, and authentication errors stop the second call.
    """
    results: dict[str, Any] = {}
    # Start with a bounded inventory call. Authentication/rate-limit failures
    # stop the sequence before any additional authorized read is attempted.
    status, sessions = json_post(
        scheme, ip, port, "/tools/invoke",
        {"tool": "sessions_list", "action": "json", "args": {"limit": 10}},
        budget, token,
    )
    results["sessions_list"] = {"status": status, "response": sessions}
    if status in (401, 403):
        return "AUTH_REQUIRED", results
    if status == 429:
        return "RATE_LIMITED", results

    # The fixed query is narrow security-configuration evidence. It is not
    # operator/target-controlled and cannot become an agent prompt or tool name.
    status, memory = json_post(
        scheme, ip, port, "/tools/invoke",
        {"tool": "memory_search", "action": "json", "args": {"query": "security configuration", "maxResults": 10}},
        budget, token,
    )
    results["memory_search"] = {"status": status, "response": memory}
    return ("AVAILABLE" if any(item["status"] == 200 for item in results.values()) else "UNAVAILABLE"), results


def legacy_probe(ip: str, port: int, budget: Budget) -> str:
    """Record whether an older endpoint still upgrades; send no agent commands."""
    status, _ = websocket_challenge(ip, port, budget)
    return status


def render_report(report: dict[str, Any]) -> str:
    """Serialize deterministic, ASCII-safe JSON for Pager loot handling."""
    return json.dumps(report, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def main() -> int:
    """Run discovery, evidence capture, authorized reads, and atomic reporting.

    Exit codes are part of the shell/Pager contract: 0 assessed (including a
    useful partial timeout), 1 authentication required, 2 unreachable, and 3
    invalid/incomplete local execution.
    """
    parser = argparse.ArgumentParser(description=f"CLAWHunter harvest engine v{VERSION}")
    parser.add_argument("--ip", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=int, default=GLOBAL_CEILING)
    parser.add_argument("--legacy-protocol", action="store_true")
    args = parser.parse_args()

    try:
        ip, port = validate_target(args.ip, args.port)
    except ValueError as exc:
        parser.error(str(exc))
    # User input can reduce the budget but can never raise the hard ceiling.
    timeout = max(1, min(args.timeout, GLOBAL_CEILING))
    budget = Budget(timeout)
    # Secrets are inherited through the environment so they stay out of argv,
    # process listings, reports, and exception messages.
    token = os.environ.get("OPENCLAW_GATEWAY_TOKEN") or os.environ.get("OPENCLAW_GATEWAY_PASSWORD")
    report: dict[str, Any] = {
        "version": VERSION,
        "target": f"{ip}:{port}",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "timeout_seconds": timeout,
        "credential_supplied": bool(token),
        "evidence": [],
    }

    # Default to a local/incomplete failure until a phase establishes a more
    # precise result. Every branch still reaches report serialization below.
    exit_code = 3
    try:
        scheme, evidence = discover_scheme(ip, port, budget)
        report["scheme"] = scheme
        report["evidence"].extend(evidence)
        if not scheme:
            report["status"] = "UNREACHABLE"
            exit_code = 2
        else:
            # Health endpoints are unauthenticated diagnostic evidence. Their
            # body is capped again in the report for readable on-device output.
            for path in ("/healthz", "/readyz"):
                try:
                    status, headers, body = http_request(scheme, ip, port, "GET", path, budget)
                    report[path] = {
                        "status": status,
                        "content_type": headers.get("content-type", ""),
                        "body": body.decode("utf-8", errors="replace")[:4096],
                    }
                except (OSError, http.client.HTTPException, ssl.SSLError) as exc:
                    report[path] = {"error": str(exc)}

            # Raw WebSocket capture is intentionally HTTP-only. TLS targets can
            # still be assessed via HTTP evidence and authorized HTTPS tools.
            if scheme == "http":
                try:
                    ws_status, challenge = websocket_challenge(ip, port, budget)
                    report["websocket"] = {"status": ws_status, "challenge": challenge}
                    if ws_status == "CHALLENGE_REQUIRED":
                        report["evidence"].append("connect.challenge")
                except (OSError, ConnectionError, TimeoutError) as exc:
                    report["websocket"] = {"error": str(exc)}

            # Policy and authentication responses are evidence; never retry with
            # altered scopes, guessed credentials, or a more privileged tool.
            tool_status, tools = read_only_tools(scheme, ip, port, budget, token)
            report["tools_invoke"] = {"status": tool_status, "results": tools}
            if args.legacy_protocol and scheme == "http":
                report["legacy_protocol"] = legacy_probe(ip, port, budget)
            report["status"] = "ASSESSED"
            exit_code = 1 if tool_status == "AUTH_REQUIRED" else 0
    # Global exhaustion is a normal partial-result condition once a transport
    # was established; before transport, it indicates an incomplete local run.
    except TimeoutError as exc:
        report["status"] = "PARTIAL_TIMEOUT"
        report["error"] = str(exc)
        exit_code = 0 if report.get("scheme") else 3
    # Preserve evidence collected before a later network/TLS failure. Only an
    # error before scheme discovery is classified as unreachable.
    except (OSError, http.client.HTTPException, ssl.SSLError) as exc:
        report["status"] = "PARTIAL_ERROR"
        report["error"] = str(exc)
        exit_code = 0 if report.get("scheme") else 2

    report["elapsed_seconds"] = round(time.monotonic() - budget.started, 3)
    # The shell chooses a loot path. Resolve it before creating parents so the
    # report records no ambiguous relative location or shell interpolation.
    output = Path(args.out).expanduser().resolve()
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        # The report names third-party hosts and the evidence gathered from them.
        # payload.sh sets umask 077 before invoking this engine, but README
        # documents running it directly, so do not rely on the caller's umask.
        # Create the file 0600 up front: writing first and chmod-ing after would
        # leave the evidence briefly world-readable.
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(render_report(report))
        # An existing report from an earlier run keeps its original mode.
        os.chmod(output, 0o600)
    except OSError as exc:
        print(f"harvest.py: failed to write {output}: {exc}", file=sys.stderr)
        return 3
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
