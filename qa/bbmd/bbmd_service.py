#!/usr/bin/env python3
"""Minimal BACnet/IP BBMD — accepts Register-Foreign-Device and replies BVLL Result(0).

Sized for live-testing the adapter's registerForeignDevice() and
_registerBbmdIfConfigured() code paths. Does NOT implement BDT forwarding or
broadcast distribution; the Foreign Device Table entry is held in memory until
TTL expiry and logged. For a real BBMD, use bacpypes3's BIPBBMDLink.

BVLL Register-Foreign-Device  (ASHRAE 135 Annex J.2.5):
    type=0x81  function=0x05  length=0x0006  ttl=<u16 seconds>
BVLL Result  (ASHRAE 135 Annex J.2.1):
    type=0x81  function=0x00  length=0x0006  result_code=0x0000 (success)
"""

# Test-infra script (not library): print logging, naive datetime, all-interface
# bind, BVLL protocol magic numbers, and signal-handler signature are
# intentional for a minimal standalone BBMD listener.
# ruff: noqa: T201, DTZ005, S104, PLR2004, ANN002, ANN202, PLW1508

import argparse
import os
import signal
import socket
import struct
import sys
import time
from datetime import datetime

BVLL_TYPE = 0x81
FN_REGISTER_FD = 0x05
FN_RESULT = 0x00
FN_DISTRIBUTE_BROADCAST_TO_NET = 0x09
RESULT_OK = 0x0000

fdt: dict[tuple[str, int], float] = {}
metrics = {"registers": 0, "renewals": 0, "expired": 0, "other_bvll": 0}


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {msg}", flush=True)


def handle_packet(sock: socket.socket, data: bytes, addr: tuple[str, int]) -> None:
    if len(data) < 4 or data[0] != BVLL_TYPE:
        return
    fn = data[1]
    if fn == FN_REGISTER_FD and len(data) >= 6:
        ttl = struct.unpack(">H", data[4:6])[0]
        new_entry = addr not in fdt
        fdt[addr] = time.time() + ttl
        if new_entry:
            metrics["registers"] += 1
            log(f"REGISTER from {addr[0]}:{addr[1]} ttl={ttl}s (FDT size={len(fdt)})")
        else:
            metrics["renewals"] += 1
            log(f"RENEW from {addr[0]}:{addr[1]} ttl={ttl}s (FDT size={len(fdt)})")
        result = struct.pack(">BBHH", BVLL_TYPE, FN_RESULT, 6, RESULT_OK)
        sock.sendto(result, addr)
    else:
        metrics["other_bvll"] += 1


def expire_fdt() -> None:
    now = time.time()
    for a in [a for a, exp in fdt.items() if exp < now]:
        metrics["expired"] += 1
        log(f"EXPIRED {a[0]}:{a[1]}")
        del fdt[a]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=int(os.environ.get("BBMD_PORT", 47900)))
    parser.add_argument("--bind", default=os.environ.get("BBMD_BIND", "0.0.0.0"))
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    sock.settimeout(5.0)
    log(f"BBMD listening on {args.bind}:{args.port}")

    def shutdown(*_):
        log(f"shutdown — metrics={metrics}")
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    last_metric = time.time()
    while True:
        try:
            data, addr = sock.recvfrom(1500)
            handle_packet(sock, data, addr)
        except TimeoutError:
            pass
        expire_fdt()
        if time.time() - last_metric > 30:
            log(f"metrics={metrics} FDT={len(fdt)}")
            last_metric = time.time()


if __name__ == "__main__":
    sys.exit(main())
