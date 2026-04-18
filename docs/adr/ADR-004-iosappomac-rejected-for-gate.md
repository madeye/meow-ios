# ADR-004: iOSAppOnMac rejected as M1 gate host

- **Status:** Accepted
- **Date:** 2026-04-18
- **Context:** v1.4 scope collapse (manual on-device QA replaces vphone-cli nightly gate)
- **Supersedes:** the earlier α/β/γ path proposal in (closed) PR #17

## Context

With the vphone-cli / Tart nightly E2E harness retired in v1.4, we re-examined whether "My Mac (Designed for iPad)" — Apple's iOSAppOnMac destination — could host the app for shared dev/CI execution. The Xcode run-destination UX suggests a zero-cost path: pick the destination, launch, done.

## Empirical findings

A dev spike on `spike/macos-host-alpha` exercised the destination end-to-end. Three blockers surfaced:

1. **`xcodebuild` silently falls back to iphoneos.** Without `macosx` in `SUPPORTED_PLATFORMS`, `xcodebuild` accepts the Mac destination flag and emits an iphoneos-only `.app` anyway — no error. Any CI step that shells out to `xcodebuild` cannot drive the Mac build path without an explicit platform widening.
2. **Mach-O Gatekeeper rejects iOS arm64 CLI launch on macOS.** Even with a well-formed iOSAppOnMac bundle, launching the binary outside the Xcode-UI launch path is blocked at the loader. There is no headless invocation that matches what Xcode does internally.
3. **NetworkExtension is unreachable.** The iOS `packet-tunnel-provider` entitlement is not honored on macOS; the macOS PTP path requires `packet-tunnel-provider-systemextension`, which is a different extension model (SystemExtension activation, user approval, different signing). iOSAppOnMac does not provide the NE surface the tunnel needs.

## Decision

**Do not pursue iOSAppOnMac as a test or gate host.** Manual on-device testing is the QA path for anything NE-touching (per v1.4 PRD §4.4 and PROJECT_PLAN T2.8).

## Consequence: dev-convenience only

The destination remains useful for non-NE UI iteration on the dev host. Task #14 enables it as a dev-convenience destination with a small settings-and-plist PR: remove `LSRequiresIPhoneOS`, drop `UIRequiredDeviceCapabilities: arm64`, add `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES`, widen `SUPPORTED_PLATFORMS` to include `macosx`. Launch is Xcode-UI only; CLI builds stay iphoneos-only by convention. Any attempt to drive NE from that launch will hit finding (3) — not a bug in the port, a property of the platform.

## References

- PR #17 (closed) — earlier α/β/γ path proposal, pre-spike.
- PROJECT_PLAN v1.4 T2.6 / T2.8 — manual smoke surface reframe.
- PRD v1.4 §4.4 — Diagnostics Surface Contract (manual QA scope).
