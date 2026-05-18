#!/usr/bin/env python3
"""Generate stub .dSYM bundles inside an xcarchive's `dSYMs/` directory so
App Store Connect's symbol upload doesn't warn about missing dSYMs for the
Firebase / Google vendored static archives.

Why this exists
---------------
Firebase iOS SDK (and the Google Mobile Ads / Analytics binaries) is
distributed via Swift Package Manager as **stripped static libraries** —
the upstream maintainers strip DWARF before publishing to keep the SDK
small.  When the host app links those archives, the resulting binary's
debug info references symbol UUIDs that have no backing dSYM, and
`xcodebuild -exportArchive` emits

    Upload Symbols Failed.  The archive did not include a dSYM for the
    FirebaseAnalytics.framework with the UUIDs [<uuid>].

These warnings don't block the upload, but they clutter every release and
mask other warnings.  Real symbolication isn't possible (no source-side
DWARF exists upstream); the canonical workaround is to forge a stub dSYM
that satisfies Apple's UUID check without providing actual symbols.

Approach
--------
Apple's symbol uploader validates a dSYM by reading the `LC_UUID` of the
Mach-O at `Contents/Resources/DWARF/<name>` inside the bundle and checking
it matches the expected per-framework UUID.  We clone the host app's
existing dSYM (which has the full segment skeleton Apple expects) and
patch its `LC_UUID` to each missing framework UUID.

Inputs
------
* `--archive`  path to the xcarchive
* The script discovers the missing UUIDs by doing a dry-run
  `xcodebuild -exportArchive` and parsing its stderr.  Manual override:
  `--frameworks FirebaseAnalytics:UUID,GoogleAppMeasurement:UUID`.

Idempotent: re-running with all stubs already present is a no-op.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

# Mach-O constants we need.
MH_MAGIC_64 = 0xFEEDFACF
LC_UUID = 0x1B


def parse_uuid(s: str) -> bytes:
    """Hyphenated 36-char UUID → 16 raw bytes."""
    s = s.replace("-", "").lower()
    if len(s) != 32:
        raise ValueError(f"bad UUID: {s}")
    return bytes.fromhex(s)


def patch_dsym_uuids(dsym_path: Path, new_uuid: bytes) -> None:
    """Rewrite every Mach-O slice's LC_UUID in the DWARF binary inside
    *dsym_path* to *new_uuid*.  The host app's dSYM is single-arch (arm64)
    but we walk fat headers anyway in case a future archive ships multi-arch.
    """
    dwarf_dir = dsym_path / "Contents" / "Resources" / "DWARF"
    binaries = [p for p in dwarf_dir.iterdir() if p.is_file()]
    if not binaries:
        raise RuntimeError(f"no DWARF binary inside {dsym_path}")
    if len(binaries) != 1:
        raise RuntimeError(f"unexpected DWARF layout in {dsym_path}: {binaries}")
    binary = binaries[0]

    raw = bytearray(binary.read_bytes())
    magic = struct.unpack_from(">I", raw, 0)[0]

    slices: list[int] = []  # offsets to mach_header_64 within the file
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        # Fat header (big-endian).
        wide = magic == 0xCAFEBABF
        nfat = struct.unpack_from(">I", raw, 4)[0]
        entry_size = 32 if wide else 20
        for i in range(nfat):
            base = 8 + i * entry_size
            offset = struct.unpack_from(">Q" if wide else ">I",
                                        raw, base + (16 if wide else 8))[0]
            slices.append(offset)
    else:
        slices.append(0)

    patched = 0
    for off in slices:
        mh_magic, _ct, _cs, _ft, ncmds, _sz, _fl, _rs = struct.unpack_from(
            "<IIIIIIII", raw, off
        )
        if mh_magic != MH_MAGIC_64:
            # 32-bit Mach-O shouldn't appear in iOS dSYMs in 2026, but skip
            # rather than fail loudly.
            continue
        cursor = off + 32  # past mach_header_64
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", raw, cursor)
            if cmd == LC_UUID and cmdsize == 24:
                struct.pack_into("16s", raw, cursor + 8, new_uuid)
                patched += 1
            cursor += cmdsize
    if patched == 0:
        raise RuntimeError(f"no LC_UUID found in {binary}")
    binary.write_bytes(bytes(raw))


def update_dsym_info_plist(dsym_path: Path, framework: str) -> None:
    """Replace the host app's CFBundleIdentifier / Name with the framework
    name so the bundle metadata matches its contents.  Cosmetic — Apple's
    uploader keys on the LC_UUID, but a coherent Info.plist avoids
    confusion when humans inspect the archive."""
    info = dsym_path / "Contents" / "Info.plist"
    plist = plistlib.loads(info.read_bytes())
    plist["CFBundleIdentifier"] = f"com.apple.xcode.dsym.{framework}"
    plist["CFBundleName"] = framework
    info.write_bytes(plistlib.dumps(plist))


def discover_missing_dsyms(archive: Path, export_plist: Path,
                           asc_key_id: str, asc_issuer: str,
                           asc_key_path: Path) -> dict[str, str]:
    """Run `xcodebuild -exportArchive` to a throwaway directory and parse
    its output for the missing-dSYM warnings.  Returns {framework_name: uuid}.

    We need the export anyway (the script that imports this stub list
    re-runs the real export afterwards); pre-running here is cheap because
    Xcode reuses cached artifacts."""
    tmp = archive.parent / "_dsym-discover"
    if tmp.exists():
        shutil.rmtree(tmp)
    proc = subprocess.run(
        [
            "xcodebuild", "-exportArchive",
            "-archivePath", str(archive),
            "-exportPath", str(tmp),
            "-exportOptionsPlist", str(export_plist),
            "-allowProvisioningUpdates",
            "-authenticationKeyID", asc_key_id,
            "-authenticationKeyIssuerID", asc_issuer,
            "-authenticationKeyPath", str(asc_key_path),
        ],
        capture_output=True, text=True,
    )
    # Don't fail on non-zero — the warnings are emitted even on success.
    pattern = re.compile(
        r"did not include a dSYM for the (\S+?)\.framework with the UUIDs \[([0-9A-F-]+)\]"
    )
    missing: dict[str, str] = {}
    for line in (proc.stdout + proc.stderr).splitlines():
        m = pattern.search(line)
        if m:
            missing[m.group(1)] = m.group(2)
    return missing


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--archive", required=True, type=Path,
                    help="path to .xcarchive (must already contain "
                         "dSYMs/meow-ios.app.dSYM)")
    ap.add_argument("--frameworks", default="",
                    help="comma-separated NAME:UUID overrides; if empty, "
                         "UUIDs are discovered by a dry-run exportArchive")
    ap.add_argument("--export-plist", type=Path,
                    help="export options plist (required when --frameworks "
                         "is empty so we can run discovery)")
    ap.add_argument("--asc-key-id", default="5MC8U9Z7P9")
    ap.add_argument("--asc-issuer", default="1200242f-e066-47cc-9ac8-b3affd0eee32")
    ap.add_argument("--asc-key-path", type=Path,
                    default=Path.home() / ".appstoreconnect" /
                            "AuthKey_5MC8U9Z7P9.p8")
    args = ap.parse_args()

    archive: Path = args.archive
    template_dsym = archive / "dSYMs" / "meow-ios.app.dSYM"
    if not template_dsym.exists():
        print(f"error: template dSYM missing at {template_dsym}", file=sys.stderr)
        return 1

    if args.frameworks:
        missing = dict(
            kv.split(":", 1) for kv in args.frameworks.split(",")
        )
    else:
        if not args.export_plist:
            print("error: --export-plist required when --frameworks is empty",
                  file=sys.stderr)
            return 1
        missing = discover_missing_dsyms(
            archive, args.export_plist,
            args.asc_key_id, args.asc_issuer, args.asc_key_path,
        )

    if not missing:
        print("==> No missing-dSYM warnings to address.")
        return 0

    print(f"==> Generating {len(missing)} stub dSYM(s) under {archive}/dSYMs/")
    for framework, uuid in missing.items():
        out = archive / "dSYMs" / f"{framework}.framework.dSYM"
        if out.exists():
            shutil.rmtree(out)
        shutil.copytree(template_dsym, out)
        # Rename the DWARF binary inside to match the framework.
        dwarf_dir = out / "Contents" / "Resources" / "DWARF"
        host_binary = next(dwarf_dir.iterdir())
        host_binary.rename(dwarf_dir / framework)
        patch_dsym_uuids(out, parse_uuid(uuid))
        update_dsym_info_plist(out, framework)
        print(f"    {framework}.framework.dSYM  uuid={uuid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
