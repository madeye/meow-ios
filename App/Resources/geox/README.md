# Bundled geo assets

This directory stages `Country.mmdb` for inclusion in the app bundle. The
mmdb itself is **not** committed to git — it's fetched from upstream by
`scripts/fetch-geo-assets.sh` (run once per developer, and once in CI before
archiving a release).

## Why a single file

Only `Country.mmdb` is bundled. The engine's other geo databases
(`geoip.metadb`, `geosite.dat`) are fetched at runtime via the `geox-url:`
block that `EffectiveConfigWriter` injects into the effective YAML (jsDelivr
mirrors of the same `MetaCubeX/meta-rules-dat@release` branch). Bundling only
`Country.mmdb` matches the Android client's pattern and keeps the IPA under
budget.

## Why commit-SHA pinning (not tag)

`MetaCubeX/meta-rules-dat` does not publish stable release tags — the only
tag upstream is `latest`, which is reassigned roughly hourly, and the
`release` branch is force-pushed on the same cadence. Neither is a stable
pin. Commit SHAs are immutable and content-addressed; combined with an
artifact SHA-256 check, this is a stronger guarantee than any upstream tag
would provide.

## Current pin

| Field                | Value                                                                |
|----------------------|----------------------------------------------------------------------|
| Upstream repo        | `MetaCubeX/meta-rules-dat`                                           |
| Pinned commit        | `f6d744b8a4a9073899d77be8de5a6fcd2fb0e755` (`release` branch HEAD)   |
| Artifact             | `country.mmdb` (renamed to `Country.mmdb` locally to match the engine's lookup casing) |
| SHA-256              | `7640321a66b2bf8fa23b599a14d473e4c98c10f173add1717b7f7cb34ae5c864`   |
| Size                 | 8,639,163 bytes (8.24 MiB)                                           |
| Fetch date           | 2026-04-18                                                           |
| Upstream license     | MIT — data repackaged by MetaCubeX from MaxMind's GeoLite2 dataset   |

## How to refresh

1. Fetch the current `release` branch HEAD SHA:
   `git ls-remote --heads https://github.com/MetaCubeX/meta-rules-dat release`
2. Download `country.mmdb` at that SHA, compute the SHA-256 and byte count.
3. Update `UPSTREAM_COMMIT`, `EXPECTED_SHA256`, and `EXPECTED_SIZE_BYTES`
   in `scripts/fetch-geo-assets.sh`.
4. Update the "Current pin" table above, including the fetch date.
5. Run `scripts/fetch-geo-assets.sh` locally to re-stage the file.
6. Open a PR with both number changes in the same diff so reviewers can
   visually confirm the pin and the hash line up.
