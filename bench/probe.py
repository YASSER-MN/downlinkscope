#!/usr/bin/env python3
"""probe.py - minimal Semtech UDP probe for the DownlinkScope test bench.

The probe sends one PULL_DATA packet (and, with --stat, one PUSH_DATA packet
that contains a gateway status) to a network server. It waits for the
acknowledgement and prints the round-trip time.

Purpose: to confirm that the gateway bridge receives UDP traffic that comes
from the gateway namespace, before the gateway simulator exists.

Packet layout (Semtech PROTOCOL.TXT, protocol version 2):
  PULL_DATA: version(1) token(2) 0x02 gateway-EUI(8)
  PULL_ACK : version(1) token(2) 0x04
  PUSH_DATA: version(1) token(2) 0x00 gateway-EUI(8) JSON
  PUSH_ACK : version(1) token(2) 0x01

Uses the Python standard library only.
"""

import argparse
import datetime
import json
import secrets
import socket
import sys
import time

PROTOCOL_VERSION = 2
PUSH_DATA, PUSH_ACK, PULL_DATA, PULL_ACK = 0x00, 0x01, 0x02, 0x04


def parse_eui(text: str) -> bytes:
    """Convert 16 hexadecimal characters to 8 bytes."""
    cleaned = text.replace(":", "").replace("-", "")
    if len(cleaned) != 16:
        raise argparse.ArgumentTypeError("the gateway EUI must have 16 hexadecimal characters")
    try:
        return bytes.fromhex(cleaned)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("the gateway EUI is not hexadecimal") from exc


def exchange(sock: socket.socket, request: bytes, ack_type: int, label: str, timeout: float) -> bool:
    """Send one request and wait for the acknowledgement with the same token."""
    token = request[1:3]
    start = time.monotonic()
    deadline = start + timeout
    try:
        sock.send(request)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise socket.timeout
            sock.settimeout(remaining)
            reply = sock.recv(2048)
            if len(reply) >= 4 and reply[1:3] == token and reply[3] == ack_type:
                rtt_ms = (time.monotonic() - start) * 1000.0
                print(f"{label}: OK, acknowledgement in {rtt_ms:.1f} ms (protocol version {reply[0]})")
                return True
            # A different packet (for example a PULL_RESP): ignore it and wait.
    except socket.timeout:
        print(f"{label}: FAIL, no acknowledgement in {timeout:g} s")
    except ConnectionRefusedError:
        print(f"{label}: FAIL, no service listens on this UDP port (ICMP port unreachable)")
    except OSError as exc:
        print(f"{label}: FAIL, network error: {exc}")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Semtech UDP probe (PULL_DATA / PUSH_DATA).")
    parser.add_argument("--server", default="10.10.2.2", help="server address (default: 10.10.2.2)")
    parser.add_argument("--port", type=int, default=1700, help="server UDP port (default: 1700)")
    parser.add_argument(
        "--gateway-eui",
        type=parse_eui,
        default=parse_eui("d15c000000000001"),
        help="gateway EUI, 16 hexadecimal characters (default: d15c000000000001)",
    )
    parser.add_argument("--stat", action="store_true", help="also send a PUSH_DATA status packet")
    parser.add_argument("--timeout", type=float, default=5.0, help="timeout in seconds (default: 5)")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((args.server, args.port))

    header = bytes([PROTOCOL_VERSION]) + secrets.token_bytes(2)
    ok = exchange(sock, header + bytes([PULL_DATA]) + args.gateway_eui, PULL_ACK, "PULL_DATA", args.timeout)

    if ok and args.stat:
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S GMT")
        stat = {"stat": {"time": now, "rxnb": 0, "rxok": 0, "rxfw": 0, "ackr": 100.0, "dwnb": 0, "txnb": 0}}
        header = bytes([PROTOCOL_VERSION]) + secrets.token_bytes(2)
        payload = json.dumps(stat, separators=(",", ":")).encode("ascii")
        ok = exchange(sock, header + bytes([PUSH_DATA]) + args.gateway_eui + payload, PUSH_ACK, "PUSH_DATA", args.timeout)

    sock.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
