# Privacy Policy — meow-ios

**Last updated:** 2026-06-28

## TL;DR

meow-ios does not collect analytics, account data, subscription contents, proxy credentials, routing rules, DNS settings, or tunneled traffic. Everything you configure stays on your device unless you explicitly export or share it.

## What the app does

meow-ios is a native iOS proxy / VPN client. When you enable the VPN toggle, the app installs a Network Extension packet tunnel that routes your device traffic through a proxy engine (meow-rs) running locally inside the extension sandbox.

Where your traffic goes from there is entirely determined by the proxy configuration **you** provide — usually a Clash YAML subscription URL. meow-ios does not operate proxy servers, and it does not know or record the contents of your subscription.

## Data we collect

The app does not collect product analytics, advertising identifiers, account
information, subscription URLs, proxy credentials, YAML configuration contents,
DNS query contents, or any traffic carried by the tunnel.

Crash logs beyond Apple's own (TestFlight / App Store crash reports) are not
collected. Apple's crash reporting can be opted into or out of in iOS Settings;
those reports go directly to Apple, and the developer sees only aggregate
summaries.

## Data stored on-device

The following items are stored locally on your device and never leave it through the app:

- Subscription URLs and the downloaded YAML configurations
- Proxy credentials contained in those configurations
- Per-app routing preferences, DNS settings, selected proxy groups
- Diagnostic logs written to the app's local sandbox

You can delete all of this by deleting the app.

## Network traffic

When the VPN is enabled, network traffic from your device is routed through whichever proxy server is specified in **your** configuration. That proxy server is operated by whoever you subscribe to — not by the meow-ios developer. meow-ios itself makes no network requests to developer-operated servers.

Subscription refreshes fetch YAML from the URL you provided, using a standard HTTPS request from within the app.

## Third parties

No analytics SDKs, advertising SDKs, attribution SDKs, A/B-testing SDKs, or
session-replay / behavioral-analytics SDKs are embedded.

Open-source on-device dependencies (the meow-rs proxy core, Yams YAML parser,
and other libraries listed in the project manifest) run entirely on-device and
do not phone home.

## Children's privacy

The app is not directed at children under 13 and collects no information from anyone.

## Changes to this policy

If this policy changes, the updated text will be committed to this repository. The "Last updated" date at the top reflects the most recent change. Users will see the new policy the next time they follow the privacy link from the App Store listing.

## Contact

Questions about this policy: open an issue at <https://github.com/madeye/meow-ios/issues> or email <max.c.lv@gmail.com>.
