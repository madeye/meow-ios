#!/usr/bin/env python3
"""Upload TestFlight metadata (beta app info + What to Test) via App Store Connect REST API.

Reads `metadata/` tree (fastlane layout) and pushes:
  - betaAppLocalizations (per locale): description, feedbackEmail, marketingUrl, privacyPolicyUrl
  - betaBuildLocalizations for the latest build (per locale): whatsNew

Uses the API key JSON at /Users/mlv/.appstoreconnect/api_key.json.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import jwt
import requests

BUNDLE_ID = "io.github.madeye.meow"
API_KEY_JSON = Path("/Users/mlv/.appstoreconnect/api_key.json")
REPO_ROOT = Path(__file__).resolve().parent.parent
METADATA_ROOT = REPO_ROOT / "metadata"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

# (locale, listing_dir, tf_dir, whats_new_file)
LOCALES = [
    (
        "en-US",
        METADATA_ROOT / "en-US",
        METADATA_ROOT / "testflight",  # en-US lives at top of testflight/
        METADATA_ROOT / "testflight" / "whats_new",
    ),
    (
        "zh-Hans",
        METADATA_ROOT / "zh-Hans",
        METADATA_ROOT / "testflight" / "zh-Hans",
        METADATA_ROOT / "testflight" / "zh-Hans" / "whats_new",
    ),
]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def make_token() -> str:
    cfg = json.loads(API_KEY_JSON.read_text())
    key_id = cfg["key_id"]
    issuer_id = cfg["issuer_id"]
    private_key = cfg["key"]
    payload = {
        "iss": issuer_id,
        "iat": int(time.time()),
        "exp": int(time.time()) + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(
        payload,
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api(session: requests.Session, method: str, path: str, **kw) -> dict:
    url = path if path.startswith("http") else f"{BASE_URL}{path}"
    r = session.request(method, url, **kw)
    if not r.ok:
        print(f"ERROR {method} {url}\n  status={r.status_code}\n  body={r.text}", file=sys.stderr)
        r.raise_for_status()
    if r.status_code == 204 or not r.content:
        return {}
    return r.json()


def find_app(session: requests.Session) -> str:
    data = api(session, "GET", "/apps", params={"filter[bundleId]": BUNDLE_ID, "limit": 1})
    items = data.get("data", [])
    if not items:
        raise SystemExit(f"no app found for bundleId={BUNDLE_ID}")
    return items[0]["id"]


def latest_build(session: requests.Session, app_id: str) -> dict:
    data = api(
        session,
        "GET",
        "/builds",
        params={
            "filter[app]": app_id,
            "sort": "-uploadedDate",
            "limit": 1,
            "fields[builds]": "version,uploadedDate,processingState,expired",
        },
    )
    items = data.get("data", [])
    if not items:
        raise SystemExit("no builds on this app yet")
    return items[0]


def existing_beta_app_loc(session: requests.Session, app_id: str) -> dict[str, str]:
    """Return {locale: localization_id} for betaAppLocalizations on this app."""
    data = api(
        session,
        "GET",
        f"/apps/{app_id}/betaAppLocalizations",
        params={"limit": 200, "fields[betaAppLocalizations]": "locale"},
    )
    return {item["attributes"]["locale"]: item["id"] for item in data.get("data", [])}


def upsert_beta_app_loc(
    session: requests.Session,
    app_id: str,
    locale: str,
    existing_id: str | None,
    attrs: dict,
) -> None:
    if existing_id:
        print(f"  PATCH betaAppLocalization[{locale}] ({existing_id})")
        api(
            session,
            "PATCH",
            f"/betaAppLocalizations/{existing_id}",
            json={"data": {"id": existing_id, "type": "betaAppLocalizations", "attributes": attrs}},
        )
    else:
        print(f"  POST  betaAppLocalization[{locale}]")
        api(
            session,
            "POST",
            "/betaAppLocalizations",
            json={
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": {"locale": locale, **attrs},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )


def existing_beta_build_loc(session: requests.Session, build_id: str) -> dict[str, str]:
    data = api(
        session,
        "GET",
        f"/builds/{build_id}/betaBuildLocalizations",
        params={"limit": 200, "fields[betaBuildLocalizations]": "locale"},
    )
    return {item["attributes"]["locale"]: item["id"] for item in data.get("data", [])}


def upsert_beta_build_loc(
    session: requests.Session,
    build_id: str,
    locale: str,
    existing_id: str | None,
    whats_new: str,
) -> None:
    if existing_id:
        print(f"  PATCH betaBuildLocalization[{locale}] ({existing_id})")
        api(
            session,
            "PATCH",
            f"/betaBuildLocalizations/{existing_id}",
            json={
                "data": {
                    "id": existing_id,
                    "type": "betaBuildLocalizations",
                    "attributes": {"whatsNew": whats_new},
                }
            },
        )
    else:
        print(f"  POST  betaBuildLocalization[{locale}]")
        api(
            session,
            "POST",
            "/betaBuildLocalizations",
            json={
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": locale, "whatsNew": whats_new},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )


def main() -> None:
    feedback_email = read_text(METADATA_ROOT / "testflight" / "beta_app_feedback_email.txt")
    marketing_url = read_text(METADATA_ROOT / "testflight" / "beta_app_marketing_url.txt")

    token = make_token()
    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {token}", "Content-Type": "application/json"})

    print(f"==> Looking up app {BUNDLE_ID}")
    app_id = find_app(session)
    print(f"    app_id={app_id}")

    build = latest_build(session, app_id)
    build_id = build["id"]
    attrs = build["attributes"]
    print(
        f"==> Latest build: id={build_id} version={attrs.get('version')} "
        f"state={attrs.get('processingState')} uploaded={attrs.get('uploadedDate')}"
    )

    print("==> Syncing betaAppLocalizations")
    existing_loc = existing_beta_app_loc(session, app_id)
    for locale, listing_dir, tf_dir, _wn in LOCALES:
        privacy_url = read_text(listing_dir / "privacy_url.txt")
        description = read_text(tf_dir / "beta_app_description.txt")
        attrs_in = {
            "description": description,
            "feedbackEmail": feedback_email,
            "marketingUrl": marketing_url,
            "privacyPolicyUrl": privacy_url,
        }
        upsert_beta_app_loc(session, app_id, locale, existing_loc.get(locale), attrs_in)

    print("==> Syncing betaBuildLocalizations (What to Test)")
    existing_bl = existing_beta_build_loc(session, build_id)
    build_version = attrs.get("version") or ""
    for locale, _ld, _tfd, wn_dir in LOCALES:
        wn_file = wn_dir / f"{build_version}.txt"
        if not wn_file.exists():
            print(f"  skip {locale}: no file {wn_file}")
            continue
        whats_new = read_text(wn_file)
        upsert_beta_build_loc(session, build_id, locale, existing_bl.get(locale), whats_new)

    print("==> Done.")


if __name__ == "__main__":
    main()
