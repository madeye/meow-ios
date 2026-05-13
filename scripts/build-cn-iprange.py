#!/usr/bin/env python3
"""
Build packed CN IP-range binaries (v4 + v6) from APNIC's delegated stats.

Output files
------------
App/Resources/geox/cn-ipv4.bin
App/Resources/geox/cn-ipv6.bin

Wire format (little-endian throughout)
--------------------------------------
   offset  size  field
        0  4     magic         = b"CNIP"
        4  1     version       = 1
        5  1     af            = 4 (cn-ipv4.bin) or 6 (cn-ipv6.bin)
        6  2     reserved      = 0
        8  4     count         = number of intervals
       12  N*K   intervals     K = 8 (v4: 2x u32) or 32 (v6: 2x u128); inclusive

Intervals are sorted ascending by `start`. Coalesced — adjacent / overlapping
ranges merge into a single span. Binary search via `partition_point` over the
slice answers contains-checks in O(log N).

Source: ftp.apnic.net/stats/apnic/delegated-apnic-latest is updated daily.
The script downloads to a temp file, parses CN entries, emits the binaries,
and prints the produced SHA-256 hashes for pinning by callers that need to
verify the bundle artifact (e.g. fetch-geo-assets.sh's pattern).

CLI
---
    scripts/build-cn-iprange.py            # download fresh APNIC stats
    scripts/build-cn-iprange.py --input X  # use a local APNIC stats file

The downloaded stats file is cached under build/cn-iprange-cache/ so repeated
runs in the same day don't re-hit the upstream.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import struct
import sys
import urllib.request
from pathlib import Path

APNIC_URL = "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_V4 = REPO_ROOT / "App" / "Resources" / "geox" / "cn-ipv4.bin"
DEFAULT_OUT_V6 = REPO_ROOT / "App" / "Resources" / "geox" / "cn-ipv6.bin"
CACHE_DIR = REPO_ROOT / "build" / "cn-iprange-cache"

MAGIC = b"CNIP"
VERSION = 1


def fetch_apnic(input_path: Path | None) -> str:
    if input_path is not None:
        return input_path.read_text(encoding="utf-8", errors="replace")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cached = CACHE_DIR / "delegated-apnic-latest.txt"
    if cached.exists():
        print(f"==> Reusing cached APNIC stats at {cached}")
        return cached.read_text(encoding="utf-8", errors="replace")
    print(f"==> Downloading {APNIC_URL}")
    with urllib.request.urlopen(APNIC_URL, timeout=60) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    cached.write_text(body, encoding="utf-8")
    return body


def parse_cn(stats: str) -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
    """Return (v4_intervals, v6_intervals) of (start_inclusive, end_inclusive).

    APNIC delegated stats lines:
      registry|cc|type|start|value|date|status[|...]
    For ipv4 `value` is the host count (always a power of two, but we treat
    it as opaque). For ipv6 `value` is the prefix length.
    """
    v4: list[tuple[int, int]] = []
    v6: list[tuple[int, int]] = []
    for line in stats.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) < 7:
            continue
        if parts[1] != "CN":
            continue
        kind = parts[2]
        start = parts[3]
        value = parts[4]
        if kind == "ipv4":
            try:
                start_int = int(ipaddress.IPv4Address(start))
                count = int(value)
            except (ValueError, ipaddress.AddressValueError):
                continue
            v4.append((start_int, start_int + count - 1))
        elif kind == "ipv6":
            try:
                net = ipaddress.IPv6Network(f"{start}/{int(value)}", strict=False)
            except (ValueError, ipaddress.AddressValueError):
                continue
            v6.append((int(net.network_address), int(net.broadcast_address)))
    return v4, v6


def coalesce(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Sort + merge overlapping/adjacent intervals."""
    if not ranges:
        return []
    ranges = sorted(ranges)
    out: list[tuple[int, int]] = [ranges[0]]
    for start, end in ranges[1:]:
        last_start, last_end = out[-1]
        if start <= last_end + 1:
            if end > last_end:
                out[-1] = (last_start, end)
        else:
            out.append((start, end))
    return out


def write_v4(path: Path, intervals: list[tuple[int, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<BBHI", VERSION, 4, 0, len(intervals)))
        for start, end in intervals:
            f.write(struct.pack("<II", start, end))


def write_v6(path: Path, intervals: list[tuple[int, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<BBHI", VERSION, 6, 0, len(intervals)))
        for start, end in intervals:
            # u128 = two u64 halves, little-endian "lo, hi".
            f.write(struct.pack("<QQ", start & 0xFFFFFFFFFFFFFFFF, start >> 64))
            f.write(struct.pack("<QQ", end & 0xFFFFFFFFFFFFFFFF, end >> 64))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, default=None, help="local APNIC stats file (skips fetch)")
    ap.add_argument("--out-v4", type=Path, default=DEFAULT_OUT_V4)
    ap.add_argument("--out-v6", type=Path, default=DEFAULT_OUT_V6)
    args = ap.parse_args()

    stats = fetch_apnic(args.input)
    v4_raw, v6_raw = parse_cn(stats)
    v4 = coalesce(v4_raw)
    v6 = coalesce(v6_raw)

    write_v4(args.out_v4, v4)
    write_v6(args.out_v6, v6)

    print(f"==> {args.out_v4}  intervals={len(v4):>6}  size={args.out_v4.stat().st_size:>9}  sha256={sha256(args.out_v4)}")
    print(f"==> {args.out_v6}  intervals={len(v6):>6}  size={args.out_v6.stat().st_size:>9}  sha256={sha256(args.out_v6)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
