#!/usr/bin/env python3
"""Register tester UDIDs (collected by Firebase App Distribution) in App Store Connect.

Workflow:
  1. A new tester accepts the Firebase invite, visits the registration page,
     and installs the configuration profile that captures their UDID.
  2. UDIDs accumulate in Firebase console → Project Settings → Apple Devices.
  3. Export the device list as CSV (button in that page).
  4. Pass the CSV to this script:

         scripts/sync-firebase-udids.py <devices.csv>

     or pipe a list of UDIDs (one per line) on stdin:

         pbpaste | scripts/sync-firebase-udids.py -

     Each new UDID is POSTed to App Store Connect /v1/devices. Already-registered
     UDIDs are skipped. After this runs, the next `xcodebuild -allowProvisioningUpdates`
     will regenerate the Ad Hoc profile to include the new devices.
"""

from __future__ import annotations

import csv
import json
import re
import sys
import time
from pathlib import Path

import jwt
import requests

API_KEY_JSON = Path("/Users/mlv/.appstoreconnect/api_key.json")
BASE_URL = "https://api.appstoreconnect.apple.com/v1"
UDID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$|^[0-9A-Fa-f]{40}$")


def make_token() -> str:
    cfg = json.loads(API_KEY_JSON.read_text())
    payload = {
        "iss": cfg["issuer_id"],
        "iat": int(time.time()),
        "exp": int(time.time()) + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(
        payload, cfg["key"], algorithm="ES256", headers={"kid": cfg["key_id"], "typ": "JWT"}
    )


def api(session: requests.Session, method: str, path: str, **kw) -> dict:
    r = session.request(method, f"{BASE_URL}{path}", **kw)
    if not r.ok:
        print(f"ERROR {method} {path}: {r.status_code} {r.text}", file=sys.stderr)
        r.raise_for_status()
    return {} if not r.content else r.json()


def parse_input(source: str) -> list[tuple[str, str]]:
    """Return [(udid, name), ...] from a CSV, plain-text list, or stdin."""
    if source == "-":
        text = sys.stdin.read()
    else:
        text = Path(source).read_text(encoding="utf-8")

    out: list[tuple[str, str]] = []

    # Try CSV first
    try:
        reader = csv.reader(text.splitlines())
        rows = list(reader)
        if rows and any("device" in c.lower() or "udid" in c.lower() for c in rows[0]):
            # Header row present — find UDID and name columns
            header = [c.strip().lower() for c in rows[0]]
            udid_col = next(
                (i for i, c in enumerate(header) if "udid" in c or "device id" in c or "deviceid" in c),
                None,
            )
            name_col = next((i for i, c in enumerate(header) if "name" in c), None)
            if udid_col is not None:
                for row in rows[1:]:
                    if udid_col >= len(row):
                        continue
                    u = row[udid_col].strip()
                    n = row[name_col].strip() if name_col is not None and name_col < len(row) else ""
                    if u:
                        out.append((u, n or f"Tester device ({u[:8]})"))
                return out
    except Exception:
        pass

    # Fallback: one UDID per line
    for line in text.splitlines():
        u = line.strip().split(",")[0].strip()
        if not u or u.startswith("#"):
            continue
        out.append((u, f"Tester device ({u[:8]})"))
    return out


def get_existing_udids(session: requests.Session) -> set[str]:
    udids: set[str] = set()
    next_url = f"{BASE_URL}/devices?fields[devices]=udid,status&limit=200"
    while next_url:
        r = session.get(next_url)
        r.raise_for_status()
        data = r.json()
        for item in data.get("data", []):
            u = item["attributes"].get("udid")
            if u:
                udids.add(u.lower())
        next_url = data.get("links", {}).get("next")
    return udids


def register_device(session: requests.Session, udid: str, name: str) -> bool:
    body = {
        "data": {
            "type": "devices",
            "attributes": {
                "name": name[:50] or "Tester device",
                "udid": udid,
                "platform": "IOS",
            },
        }
    }
    r = session.post(f"{BASE_URL}/devices", json=body)
    if r.status_code == 201:
        return True
    if r.status_code == 409:
        return False  # already exists, but our pre-check should have caught it
    print(f"  ERROR registering {udid}: {r.status_code} {r.text}", file=sys.stderr)
    return False


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <devices.csv | - >", file=sys.stderr)
        sys.exit(2)

    entries = parse_input(sys.argv[1])
    if not entries:
        print("no UDIDs parsed from input", file=sys.stderr)
        sys.exit(1)

    valid = []
    for u, n in entries:
        if UDID_RE.match(u):
            valid.append((u, n))
        else:
            print(f"  skip (not a valid UDID): {u}", file=sys.stderr)
    if not valid:
        print("no valid UDIDs in input", file=sys.stderr)
        sys.exit(1)

    token = make_token()
    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {token}", "Content-Type": "application/json"})

    print(f"==> Fetching existing devices from App Store Connect")
    existing = get_existing_udids(session)
    print(f"    {len(existing)} already registered")

    added = 0
    skipped = 0
    for udid, name in valid:
        if udid.lower() in existing:
            skipped += 1
            continue
        print(f"  + {udid}  ({name})")
        if register_device(session, udid, name):
            added += 1
            existing.add(udid.lower())

    print(
        f"==> Done. {added} new device(s) registered, {skipped} already present, "
        f"{len(valid)} total in input."
    )
    if added:
        print(
            "    Next: rebuild the Ad Hoc IPA — `scripts/build-adhoc.sh` will pick up the\n"
            "    refreshed Ad Hoc provisioning profile via -allowProvisioningUpdates."
        )


if __name__ == "__main__":
    main()
