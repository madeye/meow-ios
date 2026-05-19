# Geoip download fails with TLS error — bootstrap-tunnel chicken-and-egg, second variant

**Date:** 2026-05-19
**Investigator:** Claude Opus 4.7 driven by max.c.lv@gmail.com
**Tool chain:** Source-only audit of `claude/investigate-and-document-fHUtC`
against current `main`. A single user screenshot was the trigger; no new
device reproduction was run.

## TL;DR

Symptom (operator-reported screenshot, zh-Hans device on 5G cellular):

* Status badge `未连接` (Not connected).
* Error banner:
  * Title: `无法启动隧道`.
  * Detail: `Failed to download geoip: TLS 错误导致安全连接失败`.
* Traffic counters show `入站 14 / 出站 12` — tens of bytes flowed before
  the failure; consistent with the bootstrap tunnel briefly coming up and
  being torn back down.

The string assembles to **`Failure.downloadFailed(name: "geoip",
underlying: URLError(.secureConnectionFailed))`** raised by
`GeoAssetService.download` (`App/Sources/Services/GeoAssetService.swift:94-96`).
`Failure.errorDescription` interpolates `underlying.localizedDescription`
(`App/Sources/Services/GeoAssetService.swift:26-28`), and on a zh-Hans
device CFNetwork renders `NSURLErrorSecureConnectionFailed` (`-1200`,
`kCFErrorDomainCFNetwork`) as exactly `TLS 错误导致安全连接失败`.
Neither half of the string lives in
`App/Resources/zh-Hans.lproj/Localizable.strings` — the banner title
`无法启动隧道` is the only app-side string here
(`App/Resources/zh-Hans.lproj/Localizable.strings:62`).

**The download path runs THROUGH a minimal bootstrap tunnel**, not direct.
`VpnManager.bootstrapGeoDownload` (`App/Sources/Services/VpnManager.swift:91-114`)
writes a `MinimalConfigBuilder` config containing only the user profile's
first proxy plus a `MATCH,<first-proxy>` rule
(`MeowShared/Sources/MeowModels/MinimalConfigBuilder.swift:26-41`), starts
the tunnel, waits for `NEVPNStatus = .connected`, then issues the
`URLSession` download. So the TLS handshake that fails happens **inside**
the tunnel, dispatched through the first proxy, not from the bare iOS
network stack to `cdn.jsdelivr.net` directly.

This is the **second variant** of the geoip-download chicken-and-egg. The
first variant — `请求超时` (timeout) caused by jsDelivr being unreachable
direct from mainland China — was fixed in `dd12fe6 feat(geo): bootstrap
geo download via first proxy` (2026-05-17). That commit moved the request
through the proxy and resolved the timeout class. The TLS class is left
unaddressed: a `URLError(.secureConnectionFailed)` raised mid-proxy
manifests identically to a direct-connection TLS failure, and the
bootstrap proxy path widens the surface for it rather than narrowing it.

## How the error string is assembled

Two halves, two origins:

1. **`无法启动隧道`** — app-side, localized.
   * Key: `home.error.tunnelFailed.title`
     (`App/Resources/zh-Hans.lproj/Localizable.strings:62`).
   * Displayed by the home error banner over the `lastError` body.

2. **`Failed to download geoip: TLS 错误导致安全连接失败`** — body, two
   sub-parts joined by `: `:
   * Static prefix `Failed to download geoip` from
     `Failure.errorDescription` in `GeoAssetService`:

     ```swift
     case let .downloadFailed(name, underlying):
         "Failed to download \(name): \(underlying.localizedDescription)"
     ```

     (`App/Sources/Services/GeoAssetService.swift:26-28`)
     The `name` is whichever key in the effective config's `geox-url`
     block failed first — here `"geoip"`, which under the default block is
     `https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb`
     (`MeowShared/Sources/MeowModels/EffectiveConfigWriter.swift:30`).
   * Suffix `TLS 错误导致安全连接失败` is the system zh-Hans rendering of
     `NSURLErrorSecureConnectionFailed` (`-1200`,
     `kCFErrorDomainCFNetwork`). This is **not** in the app's strings
     file — `grep -i 'tls\|安全\|secure'` against
     `App/Resources/zh-Hans.lproj/Localizable.strings` returns nothing.
     The English equivalent CFNetwork ships is "An SSL error has occurred
     and a secure connection to the server cannot be made."

The `Failure.httpStatus` case (non-2xx HTTP) is **not** in play here —
that branch returns a `Failed to download geoip (HTTP <code>)`-shaped
string with parentheses, not the `: TLS 错误…` shape we see.

## Code path that produced this banner

The bootstrap-tunnel dance is the only path that reaches the URLSession
download today. There is no direct-from-cell fallback. The full sequence
the screenshot captured:

1. User taps the red `连接` button.
   `HomeView` calls `VpnManager.connect()`
   (`App/Sources/Services/VpnManager.swift:64`).
2. `connect()` clears `lastError`, sets `stage = .preparing`
   (`App/Sources/Services/VpnManager.swift:65-68`).
3. `GeoAssetService.allFilesPresent()` returns `false` — at least one of
   `geoip.metadb`, `country.mmdb`, `geosite.dat`,
   `GeoLite2-ASN.mmdb` is missing from
   `AppGroup.mihomoConfigDir`
   (`App/Sources/Services/GeoAssetService.swift:38-47`).
4. `bootstrapGeoDownload(manager:)` runs
   (`App/Sources/Services/VpnManager.swift:91-114`):
   * Reads source YAML from `AppGroup.configURL`.
   * Builds the minimal config — only the first proxy in `proxies:`
     and `rules: [MATCH,<first-proxy-name>]`
     (`MeowShared/Sources/MeowModels/MinimalConfigBuilder.swift:34-40`).
   * Writes minimal YAML over `configURL` (with a `defer`-scoped
     best-effort restore on every exit path,
     `App/Sources/Services/VpnManager.swift:96-101`).
   * `manager.connection.startVPNTunnel()` and
     `waitForStatus(.connected, timeout: 30)`
     (`App/Sources/Services/VpnManager.swift:103-104`). This is when the
     14/12 in/out byte counters in the screenshot started ticking —
     mihomo-rust booted, the TUN attached, the first proxy was dialed.
   * `GeoAssetService.ensureFiles(prefs:)` iterates the effective
     `geox-url` block and downloads each missing file via an ephemeral
     `URLSession` (60 s request / 180 s resource timeout,
     `App/Sources/Services/GeoAssetService.swift:81-87`). Per-URL
     packets are routed through the iOS routing table → into the TUN we
     just brought up → into mihomo-rust → MATCH → first proxy →
     upstream → `cdn.jsdelivr.net`.
5. On `geoip` (the first key iterated, in dictionary order over
   `defaultGeoXURL` — order matters for which file's name appears in
   the message), `session.download(from:)` throws
   `URLError(.secureConnectionFailed)`.
6. `GeoAssetService` re-throws `Failure.downloadFailed(name: "geoip",
   underlying: <the URLError>)`
   (`App/Sources/Services/GeoAssetService.swift:94-96`).
7. `bootstrapGeoDownload`'s `do/catch`
   (`App/Sources/Services/VpnManager.swift:105-111`) calls
   `manager.connection.stopVPNTunnel()` and waits up to 10 s for
   `.disconnected`, then re-throws.
8. `connect()`'s outer catch
   (`App/Sources/Services/VpnManager.swift:74-77`) sets
   `lastError = error.localizedDescription` and `stage = .error`.
9. The `.preparing → .stopped` collapse normally swallowed by
   `applyConnectionStatus` (`App/Sources/Services/VpnManager.swift:210`,
   intentional to not flash "Stopped" mid-bootstrap) does **not** apply
   here because the failure path explicitly assigns `stage = .error`.
   `HomeView` then renders `lastError` in the orange banner and the
   primary card flips to `未连接`.
10. The `defer` from step 4 restores the source YAML to `configURL`, so
    the next connect attempt will re-run the bootstrap from the same
    starting state. There is no progress made — the bootstrap is
    all-or-nothing.

## Why `URLError(.secureConnectionFailed)` specifically

`-1200` is iOS's "the TLS handshake didn't produce a verified, usable
session" bucket. CFNetwork raises it for, among other things:

* Server hello whose certificate chain doesn't validate against the
  iOS trust store (expired leaf, missing intermediate, hostname
  mismatch, untrusted root).
* TLS protocol-level failure during the handshake (alert from
  peer, unexpected close, no compatible cipher, malformed record).
* SNI / ALPN negotiation that the OS rejects.
* Some middlebox-injected RST mid-handshake.

It is **not** the same as `-1202` (`.serverCertificateUntrusted`),
`-1203` (`.serverCertificateHasUnknownRoot`), or `-1204`
(`.serverCertificateNotYetValid`) — those carry more specific reasons.
The fact that the kernel chose the generic `-1200` rules out a
cert-chain-specific cause we could pinpoint without packet capture.

Because the request rides the tunnel, the TLS handshake observed by
URLSession is between **the iOS device and `cdn.jsdelivr.net`** —
mihomo-rust just forwards encrypted bytes through the first proxy. The
proxy can't "fail" the TLS handshake itself (it has no key for jsDelivr),
but it can:

* Drop or corrupt handshake records → URLSession sees an unexpected
  close → `-1200`.
* Connect to the wrong upstream (e.g., a captive portal at the cellular
  carrier transparently rewrote DNS for `cdn.jsdelivr.net` before the
  proxy dialed) → certificate served doesn't match `*.jsdelivr.net` →
  `-1200`.
* Be reached over a hop that's doing TLS interception → cert presented
  to URLSession is the interceptor's, not pinned-trusted by iOS →
  `-1200`. (No certificate pinning is configured in
  `GeoAssetService.download`; iOS system trust store is the sole
  authority.)

The screenshot's 5G cellular context is the highest-prior hypothesis: a
cellular operator middlebox (or upstream-of-proxy network) interfering
with the jsDelivr handshake. The bytes-flowed counters (14/12) say the
proxy did dial something — but they don't say it dialed the right
endpoint, and we have no log of what error mihomo-rust internally
recorded (the MATCH path doesn't surface dial-level errors to the app;
URLSession sees only the eventual handshake outcome).

## What this rules in and out

Ruled **in**:

* Bootstrap tunnel reached `.connected` (otherwise we'd have failed at
  `waitForStatus`, surfacing `URLError(.timedOut)` not
  `.secureConnectionFailed`).
* TUN routing did funnel the request — there were packets
  (`入站 14 / 出站 12`).
* TLS handshake to `cdn.jsdelivr.net` was attempted and rejected by
  iOS, not by the proxy. The proxy can't synthesize a `-1200` for the
  app; the OS makes that determination on bytes it received.

Ruled **out**:

* App-side TLS pinning / custom validation: there is none.
  `URLSessionConfiguration.ephemeral` with no `URLSessionDelegate`
  means iOS system trust store and nothing else
  (`App/Sources/Services/GeoAssetService.swift:81-87`).
* HTTP-level failure (404 / 5xx / certificate explicitly untrusted):
  those would route through `Failure.httpStatus` or one of the more
  specific `URLError` codes, producing a different banner shape.
* Bundled-geoip regression: there is no bundled `geoip.metadb` anymore
  (`e442d7b feat(geo): lazy-download GeoIP/ASN databases on connect`
  removed it). Every fresh install hits this path.
* Engine-side download (mihomo-rust honoring `geox-url` itself):
  it does **not**. `GeoAssetService` comment is explicit —
  "mihomo-rust does NOT itself honor `geox-url` for lazy fetching"
  (`App/Sources/Services/GeoAssetService.swift:8-10`). The app stages
  files; the engine reads them off disk. So this failure can't be
  attributed to anything in `core/rust/mihomo-ios-ffi/`.

Not yet determinable without more data:

* Whether the user's first proxy itself is degraded (e.g., the
  TLS-tunneled VLESS endpoint is up enough for the dial to succeed
  but is forwarding garbage). Repro with a known-good first proxy
  on the same network would disambiguate.
* Whether jsDelivr is the unhappy endpoint, vs. the cellular
  carrier intercepting it. A simultaneous direct-from-Wi-Fi test
  would disambiguate.

## Default geox-url block (the URLs being attempted)

From `MeowShared/Sources/MeowModels/EffectiveConfigWriter.swift:29-34`,
injected when the user's profile doesn't ship `geox-url`:

```yaml
geox-url:
  geoip:   https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb
  mmdb:    https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb
  geosite: https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat
  asn:     https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb
```

All four point at `cdn.jsdelivr.net`, a single SAN
(`*.jsdelivr.net` + apex) on Fastly/Cloudflare-fronted infrastructure.
Single-CDN exposure means a single endpoint problem (cert renewal hiccup,
CDN regional incident, ISP-level interception of that specific host)
takes the entire bootstrap down for everyone — there is no mirror.

The user *can* override `geox-url` in their profile YAML, but no current
UX surfaces this; an end user hitting this banner has no obvious path
out other than retrying on a different network.

## Surrounding context — why this matters more than a transient

The bootstrap-tunnel fix `dd12fe6` is one week old. Before it, the
direct-from-cell path was the failure mode and users saw a timeout
banner; the fix turned that into "we have a tunnel for the geoip fetch,
which should make this near-perfect." The TLS variant says the new path
is not actually perfect — it's narrower than direct, but it inherits a
new dependency on **whatever the first proxy does to TLS to jsDelivr**.
Operators who never saw `请求超时` before may now see
`TLS 错误导致安全连接失败` instead, with no path to recover other than
restarting the app on a different network.

The blast radius is **first connect on every install**. Once any of the
four files lands on disk, `allFilesPresent` becomes a fast path
(`App/Sources/Services/GeoAssetService.swift:38-47` — non-zero file size
is the only check, no HEAD revalidation), and the bootstrap is never
re-entered until the user manually deletes the files or reinstalls. So
the failure is bursty and onboarding-shaped, not steady-state. That
matches the screenshot: a fresh-install or post-reinstall user trying
to come up for the first time.

## Suggested next steps (not implemented in this pass)

Listed in order of "smallest change first," not necessarily preferred
order. Each carries a separate tradeoff; the right pick depends on
whether we want to **avoid** the failure, **recover** from it, or
**explain** it better.

1. **Multi-mirror fallback in `GeoAssetService.download`**. Try jsDelivr
   first, then a list of alternates (`raw.githubusercontent.com`,
   `ghproxy.com`, `fastly.jsdelivr.net` direct, `gcore.jsdelivr.net`
   etc.) on any `URLError` whose `code` is in
   `{.secureConnectionFailed, .cannotConnectToHost, .timedOut,
   .networkConnectionLost, .notConnectedToInternet}`. Cheapest user-
   visible improvement; the alternates list could ship as a constant on
   `EffectiveConfigWriter` alongside `defaultGeoXURL`.

2. **Bundle the four files in-app** and use `GeoAssetService` only to
   refresh stale ones. Removes the entire chicken-and-egg from
   first-connect — the bootstrap tunnel is no longer needed at all.
   Costs ~5–6 MB of IPA (the four files together) and reintroduces
   what `e442d7b` deliberately removed; revisiting that decision is a
   separate conversation. The "fresh install on cellular" UX is the
   strongest argument for this.

3. **Pluggable bootstrap proxy**. The current first-proxy choice is
   "whatever's first in the YAML." If a user's first proxy is a
   slow/degraded shadowsocks node, that's what gets stuck handling the
   jsDelivr handshake. Letting the user pin a known-good bootstrap
   proxy (or auto-selecting based on latency) would harden the path.
   Larger change; touches UI.

4. **Surface the specific URLError code in the banner.** Today the
   user gets the OS-localized blurb. Adding the URLError code (`-1200`)
   plus the URL host (`cdn.jsdelivr.net`) to the banner would make
   user-reported screenshots immediately actionable instead of
   requiring this whole investigation each time. Cheap, fully app-side,
   doesn't change failure rate but reduces investigation cost.

5. **Bridge mihomo-rust's dial-level error to URLSession's view.**
   When the first proxy fails its upstream dial mid-TLS, the app today
   sees only `URLError(.secureConnectionFailed)`. If we exposed a
   shared-store breadcrumb (`SharedStore.readState()`) from mihomo-rust
   for "last dial outcome on the bootstrap config," the
   `bootstrapGeoDownload` catch path could include it in the rethrown
   error and the banner would say something like "proxy dial failed:
   <reason>" instead of a generic TLS message. Larger change, touches
   FFI; useful diagnostic improvement, not a fix.

## File reference

```
App/Sources/Services/VpnManager.swift:64-114        — connect() + bootstrapGeoDownload()
App/Sources/Services/GeoAssetService.swift          — entire file is in scope
  :20-32                                              Failure enum + errorDescription
  :38-47                                              allFilesPresent() fast path
  :54-66                                              ensureFiles()
  :79-110                                             download() + URLSession config
MeowShared/Sources/MeowModels/EffectiveConfigWriter.swift:29-34  — defaultGeoXURL
MeowShared/Sources/MeowModels/MinimalConfigBuilder.swift         — bootstrap config
MeowShared/Sources/MeowModels/VpnState.swift:3-16                — VpnStage enum
App/Resources/zh-Hans.lproj/Localizable.strings:62               — banner title
```

Relevant commits:

```
dd12fe6  feat(geo): bootstrap geo download via first proxy   (2026-05-17)
e442d7b  feat(geo): lazy-download GeoIP/ASN databases on connect
6c8cf36  feat(mihomo): enable boring-tls feature for ECH support  (adjacent, not causal)
```

No GitHub issue currently filed for this specific banner. `gh search`
across `madeye/meow-ios` for `geoip OR jsdelivr OR "无法启动隧道" OR
"Failed to download" OR TLS` returned only #112 (YAML import format,
unrelated).
