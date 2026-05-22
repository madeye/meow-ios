# Integration-test fixtures

## GeoIP2-Country-Test.mmdb

- **Source:** `github.com/maxmind/MaxMind-DB`
- **Pinned commit:** `05a275aae93456b61b27c20a2766e9b30717be8b`
- **URL:** https://github.com/maxmind/MaxMind-DB/raw/05a275aae93456b61b27c20a2766e9b30717be8b/test-data/GeoIP2-Country-Test.mmdb
- **SHA-256:** `b37601903448683d241af52893c8cbf0fed461e0cdebe0bfaca01891fdeb6db9`
- **Size:** 19,492 bytes
- **License:** MIT (MaxMind-DB is dual-licensed Apache-2.0 OR MIT; this crate elects MIT — see `LICENSE-MIT` at the pinned commit)

Synthetic test data — no real user IPs. Probed in `tests/xdg_home_dir_test.rs`:

- `214.78.120.1` → `US` (per `source-data/GeoIP2-Country-Test.json` at the pinned commit, range `214.78.120.0/22`)

To refresh the fixture, update the pinned commit above, re-download, and verify the SHA-256 matches before committing.
