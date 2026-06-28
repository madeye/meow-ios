# scripts/

Build, packaging, and release-automation helpers for meow-ios. Run all
scripts from the repo root unless noted; they re-resolve `$ROOT` from
`$BASH_SOURCE` so absolute vs. relative `cwd` doesn't matter.

## build-rust.sh

Builds `core/rust/meow-ios-ffi` for `aarch64-apple-ios` (device) and the
two simulator targets (`aarch64-apple-ios-sim`, `x86_64-apple-ios`), packs
them into `MeowCore/MeowCore.xcframework`, and regenerates the C header
`MeowCore/include/meow_core.h` via cbindgen. Prerequisites: stable Rust
toolchain with the three iOS targets installed (`rustup target add ...`)
and `cbindgen` on `$PATH`. No env vars required.

## build-release.sh

Builds a Release-configuration iOS app bundle and optionally installs it
onto a USB-connected device. Mostly used during local QA; for distribution
prefer `build-adhoc.sh` or `upload-testflight.sh`. No required env vars,
but reads `$DEVELOPMENT_TEAM` if you want to override the default team
(`SK4GFF6AHN`).

## build-adhoc.sh

Builds a Release IPA signed with the **Ad Hoc** App Store Connect
distribution profile (`release-testing` method) and exports it to
`build/export-adhoc/meow-ios.ipa` for direct device or external distribution. Calls
`build-rust.sh` first unless `--skip-rust-build` is passed. Warns when the bundled provisioning profiles are within 30 days
of expiry. Env vars: `APP_PROFILE`, `PT_PROFILE` (UUIDs under
`~/Library/MobileDevice/Provisioning Profiles/`), `DEVELOPMENT_TEAM`,
`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`. Prerequisites: Xcode 16+,
the matching profiles + Apple Distribution identity in the login keychain,
and the App Store Connect API key on disk.

## upload-testflight.sh

Builds a Release IPA signed with the **App Store** distribution profile
and uploads it to App Store Connect / TestFlight (`destination=upload`,
`method=app-store-connect`). Warns on provisioning profile near-expiry.
Flags: `--skip-rust-build`, `--skip-archive` (reuses
`build/meow-ios-appstore.xcarchive`), `--skip-upload` (archive-only). Env
vars: same as `build-adhoc.sh`, but with the App Store profile UUIDs.
Pair with `upload-testflight-metadata.py` to push the build's "What to
Test" notes once App Store Connect finishes processing.

## upload-testflight-metadata.py

Pushes per-locale TestFlight metadata (`betaAppLocalizations`,
`betaBuildLocalizations`) from a fastlane-shaped `metadata/` tree via the
App Store Connect REST API. Reads the API key from
`~/.appstoreconnect/api_key.json` (or `$ASC_API_KEY_JSON`). Run after
`upload-testflight.sh` once App Store Connect has finished processing the
build. Prerequisites: Python 3.11+, `pyjwt`, `requests`.

## generate-app-icon.sh

Regenerates the iOS `AppIcon.appiconset` PNG and `docs/appicon.png` from the
meow-rs website logo at `../meow-rs/website/public/logo.svg`. Idempotent;
prerequisites: `rsvg-convert`, `python3`, `Pillow`, and that source path
existing on the build host.

## generate-xcodeproj.sh

Regenerates `meow-ios.xcodeproj` from `project.yml` via `xcodegen`. Run
whenever `project.yml` changes. Prerequisite: `brew install xcodegen`.
