# ADR-005: Download geoip via in-process meow proxy, not via a bootstrap tunnel

- **Status:** Accepted
- **Date:** 2026-05-19 (proposed), 2026-05-20 (accepted)
- **Author:** Claude Opus 4.7 driven by max.c.lv@gmail.com
- **Builds on:** `INVESTIGATION-2026-05-19-geoip-download-tls-failure.md`
- **Supersedes (if accepted):** the bootstrap-tunnel approach in commit
  `dd12fe6 feat(geo): bootstrap geo download via first proxy`
  (2026-05-17), specifically `VpnManager.bootstrapGeoDownload`
  (`App/Sources/Services/VpnManager.swift:91-114`).

## Context

The current first-connect path for any install missing geoip/geosite/
mmdb/asn does the following dance, per
`App/Sources/Services/VpnManager.swift:64-114`:

1. Build a minimal config (first proxy + `MATCH,<first-proxy>`).
2. Overwrite the real config with the minimal one.
3. Call `NETunnelProviderManager.connection.startVPNTunnel()`.
4. Poll for `NEVPNStatus = .connected` (up to 30 s).
5. `GeoAssetService.ensureFiles` → `URLSession.download` for each
   `geox-url` — the TUN routes those requests through meow-rs through
   the first proxy.
6. `stopVPNTunnel()`, wait for `.disconnected` (up to 10 s).
7. Restore the real config (via `defer`).
8. Call `startVPNTunnel()` again with the real config.

This works most of the time, but the operator-facing failure mode is
now `URLError(.secureConnectionFailed)` (CFNetwork `-1200`) surfacing as
`Failed to download geoip: TLS 错误导致安全连接失败` — investigated in
`docs/INVESTIGATION-2026-05-19-geoip-download-tls-failure.md`. The
TLS handshake observed by URLSession is between the device and
`cdn.jsdelivr.net`; the proxy carries encrypted bytes, but any
middlebox or proxy-side disturbance manifests at the URLSession layer
as a generic `-1200`. The user is left with no recovery path other
than retrying on a different network.

The dance also has structural costs we'd prefer to remove regardless
of the TLS class of failure:

* **State juggling** — `configURL` is overwritten with the minimal YAML
  and restored only via `defer`. If the app is killed between the
  overwrite and the restore, the user's profile is wedged on the
  minimal config until they reselect the profile.
* **Two NE state transitions per first connect** —
  `.disconnected → .connecting → .connected → .disconnecting →
  .disconnected → .connecting → .connected`. Each is observable to
  iOS NetworkExtension housekeeping, and the badge flicker contract
  inside `applyConnectionStatus` had to grow special-case handling
  (`App/Sources/Services/VpnManager.swift:210`) just to avoid showing
  "Stopped" mid-bootstrap.
* **Up-to-40 s of "Preparing…"** in the worst case (30 s
  `waitForStatus(.connected)` + the download + 10 s
  `waitForStatus(.disconnected)`).

## Goal

Download the four geo files through a proxy from the user's config
**without** starting `NEPacketTunnelProvider`, by running a minimal
meow engine in the App process as a local HTTP/SOCKS5 listener and
pointing `URLSession` at it.

## Non-goals

* **Replacing the TLS stack.** This design keeps URLSession (and thus
  iOS Security framework) as the TLS endpoint. Some `-1200` cases will
  still happen — they are different cases (no longer "the bootstrap
  proxy hop disturbed the handshake"). Routing TLS through Rust
  (rustls / boring-tls) is a separable concern; see "Future work
  not in scope" below.
* **Bundling geo files in the IPA.** That's an alternative way to
  remove the chicken-and-egg entirely, with its own size and freshness
  tradeoffs. Out of scope here.
* **First-proxy auto-selection.** "First proxy in the YAML" remains the
  bootstrap-proxy selection policy. Improving that is a separable
  follow-up.

## Why this is feasible — what the FFI already exposes

`MeowCore/include/meow_core.h` cleanly separates engine startup
from TUN startup:

```c
int  meow_engine_start(const char *config_path);
void meow_engine_stop(void);
int  meow_engine_is_running(void);
int  meow_tun_start(void *ctx, MeowWritePacket write_cb);
void meow_tun_stop(void);
```

`meow_engine_start` brings up:

* The mixed-port listener (HTTP + SOCKS5 on the same port, default
  `7890`), per
  `MeowShared/Sources/MeowModels/EffectiveConfigWriter.swift:22`.
* The external-controller REST API (`127.0.0.1:9090`), per
  `EffectiveConfigWriter.swift:23`.
* The proxy graph (groups, providers, rules).
* The DNS subsystem the engine uses internally.

It does **not** require `meow_tun_start` to be called. The
PacketTunnel extension calls both in sequence; the App can call only
the first.

Critically, the App target **already links `MeowCore.xcframework`**
(`project.yml:110`, mirror of `project.yml:226` for PacketTunnel) and
the App already calls FFI symbols today
(`App/Sources/Services/SubscriptionConverter.swift`,
`App/Sources/Views/UserDiagnosticsView.swift`,
`App/Sources/AppModel.swift:37`). Starting the engine in-process is
within the existing capability surface; no new dependency, no IPA-size
delta.

## Approaches considered

### A. In-process meow engine, no TUN (RECOMMENDED)

App process starts a minimal meow engine, points URLSession at
`127.0.0.1:7890` via `connectionProxyDictionary`, downloads through it,
stops the engine, then asks `NETunnelProviderManager` to start the
real tunnel with the real config.

### B. Reuse the bootstrap tunnel, add multi-mirror fallback

Keep `bootstrapGeoDownload` exactly as is, but in `GeoAssetService`
on any `URLError` in
`{.secureConnectionFailed, .cannotConnectToHost, .timedOut, .networkConnectionLost}`,
retry against a mirror list (`raw.githubusercontent.com`,
`ghproxy.com`, `gcore.jsdelivr.net`).

Cheap. Fixes some `-1200` cases (those caused by jsDelivr-specific
incidents). Does not address the structural costs above. Considered
complementary, not a replacement.

### C. Engine-side download (new FFI)

Add `meow_engine_fetch_url(url, proxy_name, out_path)`. meow-rs
opens an `meow-proxy` adapter for `proxy_name`, sends the HTTP
request using its own TLS stack (boring-tls), writes the body to
`out_path`.

Bypasses iOS URLSession entirely. Largest change — new FFI surface,
need to handle streaming-to-disk, error propagation, cancellation.
Defers the recommended approach by a release. Considered for the next
iteration if URLSession-over-loopback proves insufficient.

### D. Status quo + better banner diagnostics only

Surface the `URLError.code` and the failing host in the banner. Doesn't
fix the failure, just makes user-reported screenshots actionable in
one shot instead of requiring the investigation pipeline. Cheap; not
mutually exclusive with anything above.

## Decision: pursue Approach A

In-process engine, no TUN, loopback HTTP/SOCKS5 listener, URLSession
proxy dictionary. Approach B's mirror fallback layers cleanly on top
and should land in the same change. Approaches C and D are explicitly
out of scope here but documented so the next iteration has a starting
point.

## Detailed design

### New service: `BootstrapEngine`

A small Swift class in `App/Sources/Services/BootstrapEngine.swift`
(new file) responsible for the engine lifetime. Shape:

```swift
@MainActor
final class BootstrapEngine {
    enum Failure: LocalizedError {
        case engineStartFailed(String)
        case noProxies
        case alreadyRunning
    }

    /// Bring up an engine-only (no TUN) meow-rs against `minimalConfig`,
    /// confirmed listening on 127.0.0.1:<port>. Returns the port so
    /// callers can point URLSession at it. Idempotent: returns the
    /// existing port if already running.
    func start() async throws -> Int

    /// Stop the engine and release ports. Safe to call when not running.
    func stop() async

    /// True iff the engine is currently up in-process.
    var isRunning: Bool { get }
}
```

Internals:

* Build the minimal YAML via `MinimalConfigBuilder.build(...)` (already
  exists, no change). The minimal config doesn't reference geox-url,
  rule-providers, or DNS — exactly what we want.
* Pick a bootstrap port. Two options:
  * **Same `7890`** — risks colliding with another instance if the
    PacketTunnel extension is running. By design, bootstrap only
    runs when the tunnel is NOT up, so the conflict window is
    closed. But on iOS app extensions, the extension process can
    linger briefly after stop. Add an explicit pre-check via a
    `bind()` probe; fail fast with a clear error if 7890 is held.
  * **Random ephemeral port** — patch the minimal YAML to set
    `mixed-port: <chosen>`, returned to the caller. More robust.
    Cost: one extra patch step in MinimalConfigBuilder, plus
    `EffectiveConfigWriter.defaultMixedPort` (currently 7890) loses
    its "single source of truth" guarantee for bootstrap. **Pick
    this — random ephemeral**. Rationale: the bootstrap engine is
    transient; the PacketTunnel extension's engine still uses 7890
    long-term. Decoupling them removes a class of port-conflict
    bugs we can't easily diagnose remotely.
* Write the minimal YAML to a **separate** path
  (`AppGroup.bootstrapConfigDir/minimal.yaml`), not over
  `AppGroup.configURL`. This eliminates the `defer`-based restore
  fragility — the user's real config is never touched.
* `minimal.yaml.withCString { meow_engine_start($0) }`.
* On success, return the chosen port. The engine binds
  `127.0.0.1:<port>` (verified by a one-shot reachability probe
  `meow_engine_test_proxy_http("http://127.0.0.1:9090/", 500, ...)`
  — same cold-connect readiness pattern
  `AppModel.replaySelectedProxies` already uses
  (`App/Sources/AppModel.swift:81-91`); applied to the local
  listener instead of the REST API).
* `stop()` calls `meow_engine_stop()`; meow-rs releases the port
  synchronously on its side, but BSD socket TIME_WAIT can hold the
  port for up to ~30 s. Random-port choice neutralizes this.

### Rewiring `GeoAssetService.download`

Add a `URL` for the proxy, plumbed in by the caller:

```swift
static func ensureFiles(prefs: Preferences, throughProxy proxy: URL?) async throws { ... }

private static func download(name: String, from source: URL, to destination: URL, throughProxy proxy: URL?) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 180
    config.waitsForConnectivity = false
    if let proxy {
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String:  true,
            kCFNetworkProxiesHTTPProxy  as String:  proxy.host ?? "127.0.0.1",
            kCFNetworkProxiesHTTPPort   as String:  proxy.port ?? 7890,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy  as String: proxy.host ?? "127.0.0.1",
            kCFNetworkProxiesHTTPSPort   as String: proxy.port ?? 7890,
        ]
    }
    // ... rest unchanged
}
```

Notes:

* `kCFNetworkProxiesHTTPSProxy` instructs URLSession to use the HTTP
  proxy's `CONNECT` method for HTTPS — exactly what we want. iOS has
  supported this since iOS 10; no entitlement or ATS exception needed
  beyond what the app already has.
* The proxy URL is `URL(string: "http://127.0.0.1:<port>")`; the
  port comes from `BootstrapEngine.start()`.
* If `proxy == nil` (the path used by future direct-mode reuse),
  behavior is identical to today's `GeoAssetService.download` —
  we don't break existing callers or tests.

### New `VpnManager.connect()` flow

Replacement for `bootstrapGeoDownload` (delete that method entirely,
along with `MinimalConfigBuilder` callsite migrating from
`bootstrapGeoDownload` to `BootstrapEngine`):

```swift
func connect() async {
    lastError = nil
    if manager == nil { await refresh() }
    guard let manager else { return }
    stage = .preparing
    do {
        if !GeoAssetService.allFilesPresent() {
            let port = try await bootstrapEngine.start()
            defer { Task { await bootstrapEngine.stop() } }
            let proxy = URL(string: "http://127.0.0.1:\(port)")!
            try await GeoAssetService.ensureFiles(
                prefs: Preferences.load(from: AppGroup.defaults),
                throughProxy: proxy,
            )
        }
        try manager.connection.startVPNTunnel()
    } catch {
        lastError = error.localizedDescription
        stage = .error
    }
}
```

The `.preparing` badge window now covers:

* `bootstrapEngine.start()` — sub-second on device (cold engine init
  is dominated by config parse + rule compile, both fast for the
  minimal config which has zero rules other than `MATCH`).
* The actual download — bound by the user's first proxy's throughput.
* `bootstrapEngine.stop()` — synchronous on the FFI side.

Total replaces the old 30 s + download + 10 s with just the download
itself plus a few-hundred-ms boot. **Worst-case "Preparing…" drops by
~40 s.**

### Multi-mirror fallback (Approach B layered in)

Inside `GeoAssetService.download`, on `URLError` whose code is in
`{.secureConnectionFailed, .cannotConnectToHost, .timedOut,
.networkConnectionLost}`, walk a per-asset mirror list. Default mirror
table (a sibling of `EffectiveConfigWriter.defaultGeoXURL`):

```swift
static let geoXMirrors: [String: [String]] = [
    "geoip": [
        "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "https://gcore.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb",
        "https://ghproxy.com/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb",
    ],
    // ... similar for mmdb / geosite / asn
]
```

Iterate in order, stop on first 2xx. The mirror list is overridable
the same way `geox-url` is — if the user's profile ships a custom
`geox-url`, mirrors are not used (we don't second-guess user intent).

This is independent of Approach A and would be valuable on its own,
but ships in the same PR to keep the user-visible recovery story
coherent.

## API / file surface

New:

```
App/Sources/Services/BootstrapEngine.swift        — new file (~120 lines)
MeowShared/Sources/MeowModels/AppGroup.swift      — add bootstrapConfigDir
MeowShared/Sources/MeowModels/EffectiveConfigWriter.swift
    — add geoXMirrors constant
MeowShared/Sources/MeowModels/MinimalConfigBuilder.swift
    — overload build(...) to accept a port override
```

Modified:

```
App/Sources/Services/GeoAssetService.swift        — add throughProxy:, mirror walk
App/Sources/Services/VpnManager.swift             — connect() rewrite, delete bootstrapGeoDownload + waitForStatus
```

Deleted:

```
App/Sources/Services/VpnManager.swift:bootstrapGeoDownload(manager:)
App/Sources/Services/VpnManager.swift:waitForStatus(manager:target:timeout:)
App/Sources/Services/VpnManager.swift:applyConnectionStatus's
    .preparing → .stopped suppression branch (no longer needed,
    we never bring the tunnel up during bootstrap)
```

No new FFI, no entitlement changes, no Info.plist changes, no
ATS exceptions. `NSAllowsLocalNetworking: true` is already set on the
app (`project.yml`, `NSAppTransportSecurity` block), which is what
permits the loopback HTTP proxy in the first place.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Engine init in App process bloats cold-start. | `meow_engine_start` is only called inside `connect()`, never at launch. Cold start is unaffected. |
| App-process engine collides with PacketTunnel extension's engine on 9090 / 7890. | Random ephemeral mixed-port; the external-controller port (9090) is not actually queried during bootstrap, but we should also randomize it to be safe. Alternative: skip the `external-controller` line entirely in the minimal config — the engine doesn't need a REST API if no caller is using it. **Prefer skipping.** |
| `URLSession.connectionProxyDictionary` is ignored on iOS in some configurations. | Documented as supported since iOS 10 for HTTP and HTTPS-via-CONNECT. We can validate during dev with an iPhone 16 Pro simulator + Charles intercepting the loopback hop. Listed in test plan. |
| The user's profile's first proxy is the bootstrap proxy — same chicken-as-current. | Acknowledged. First-proxy degradation still fails. Multi-mirror fallback addresses the case where the proxy is fine but jsDelivr isn't; first-proxy reliability is a separate ADR. |
| In-process engine holds memory the app didn't need before. | Minimal config has zero rule-providers and zero geox-url, so the engine's in-memory footprint is dominated by the one proxy adapter. Expected: low single-digit MB. Need to measure. |
| Port held in TIME_WAIT after `meow_engine_stop`. | Random port per bootstrap; no impact on subsequent runs. |
| `meow_engine_start` returns before the socket is fully bound. | The cold-connect readiness probe pattern from `AppModel.replaySelectedProxies` (`App/Sources/AppModel.swift:81-91`) is the proven mitigation — 100 ms × up-to-10 retries against the loopback listener. |
| ATS rejects HTTPS-via-HTTP-proxy on loopback. | `NSAllowsLocalNetworking: true` is already in `project.yml`; this is exactly the case it's for. Adding `NSExceptionDomains` is not needed because the destination is `cdn.jsdelivr.net` (publicly HTTPS-capable), not a non-TLS host. |
| Engine startup logs leak to the app's stderr / device console. | meow-rs logging is gated by `log-level: warning` in the minimal config (`MinimalConfigBuilder.swift:37`); accept the warnings, they're useful for diagnostics. |
| User force-quits app mid-bootstrap. | Engine is in-process — dies with the app. No external cleanup needed. Contrast with the current bootstrap-tunnel approach where a force-quit between `configURL` overwrite and `defer`-restore leaves a wedged config. |

## Test plan

* **Unit:** `BootstrapEngineTests` covering start-twice (idempotent),
  stop-when-not-running (no-op), start-fails-when-port-held
  (synthetic — bind 127.0.0.1:7890 in the test then attempt to
  start; this only applies if we don't go with random-port).
* **Unit:** `GeoAssetServiceTests` extended with a fake URLSession
  scenario that returns `URLError(.secureConnectionFailed)` on URL #1,
  succeeds on URL #2 — verifies mirror walk picks the right asset and
  writes atomically.
* **Integration (`MeowIntegrationTests`):** start `BootstrapEngine` against
  a real minimal config pointing at a single test-proxy, fetch a
  small fixture via `URLSession.connectionProxyDictionary`, verify
  bytes match. Skip on CI if a test proxy isn't available; mark as
  `#if INTEGRATION`.
* **Manual on-device (per CLAUDE.md QA path):** iPhone 16 Pro on
  iOS 26, fresh install, real subscription. Confirm:
  * First connect succeeds within ~5 s of "Preparing…" (vs current
    ~30 s+).
  * `configURL` on disk is never overwritten with the minimal
    config (compare before/after `connect()`).
  * `NEVPNStatus` only transitions once
    (`.disconnected → .connecting → .connected`), not twice.
  * Force-quitting the app mid-download leaves the user's profile
    intact.
* **Manual failure paths:**
  * Cellular with first-proxy intentionally pointed at a bad endpoint
    → engine starts, download fails, mirror walk fails, error banner
    says "Failed to download geoip" with a more specific URLError
    code (Approach D layered in — see below).
  * Cellular with first-proxy fine but jsDelivr blocked → mirror walk
    catches it on the second mirror.

## Rollout

Single PR, no feature flag. Justification:

* The change is bounded to first-connect when geo files are missing.
* Subsequent connects on the same install never enter this path
  (`allFilesPresent()` fast path,
  `App/Sources/Services/GeoAssetService.swift:38-47`).
* Rollback is straightforward: revert the PR; existing-install users
  with geo files on disk are unaffected.
* No schema, no on-disk format change, no shared-store / IPC
  contract change.

## Future work not in scope

* **Engine-side TLS for geo downloads (Approach C).** If
  URLSession-over-loopback proves to still hit `-1200` for reasons
  outside our control (e.g., iOS Security framework strictness on
  some jsDelivr-served chains), revisit with a `meow_engine_fetch_url`
  FFI that uses meow's TLS stack.
* **Bundling geo files in the IPA.** Removes the chicken-and-egg
  entirely; ~5–6 MB IPA cost. Deserves its own ADR weighing IPA size
  vs onboarding reliability.
* **Banner diagnostics (Approach D).** Cheap and orthogonal; should
  land regardless of which path we pick, but is out of scope here
  to keep this ADR focused.
* **Pluggable bootstrap-proxy selection.** "First proxy" is a sharp
  edge if the user's first proxy is degraded. Auto-select fastest /
  let user pin a bootstrap proxy. Out of scope.

## References

* `INVESTIGATION-2026-05-19-geoip-download-tls-failure.md` — symptom
  walkthrough and ruling.
* `dd12fe6 feat(geo): bootstrap geo download via first proxy` — the
  approach this ADR proposes to supersede.
* `e442d7b feat(geo): lazy-download GeoIP/ASN databases on connect`
  — the commit that removed bundled geo assets, creating the
  chicken-and-egg in the first place.
* `App/Sources/AppModel.swift:81-91` — cold-connect readiness probe
  pattern, reused here for "is the loopback listener up yet."
* `MeowCore/include/meow_core.h` — FFI surface that already
  supports engine-without-TUN.
