# macos-utun-harness — `meow-utun`

A developer-only macOS test binary that wires the same FFI surface the iOS
`PacketTunnelProvider` drives (`meow_core_*`, `meow_engine_*`,
`meow_tun_*`) into a real `utun` device, so the engine + fake-IP DNS +
CN-bypass + tun2socks paths can be exercised with actual packets without
an iPhone and without the iOS Simulator (which has no TUN host).

## Build

```bash
cd core/rust/macos-utun-harness
cargo build --release
```

Produces `target/release/meow-utun`. Apple silicon only (the engine is
built for `aarch64-apple-darwin`).

## Run

```bash
# Prepare a home directory mirroring the AppGroup container layout:
mkdir -p /tmp/meow-home/meow
cp /Volumes/DATA/workspace/meow-ios/App/Resources/geox/Country.mmdb /tmp/meow-home/meow/
cp /Volumes/DATA/workspace/meow-ios/App/Resources/geox/cn-ipv4.bin   /tmp/meow-home/meow/
cp /Volumes/DATA/workspace/meow-ios/App/Resources/geox/cn-ipv6.bin   /tmp/meow-home/meow/

# Hand it an iOS-style effective-config.yaml.
sudo ./target/release/meow-utun \
    --config /path/to/effective-config.yaml \
    --home   /tmp/meow-home
```

The binary opens utun, prints `utun ready as utunN`, then waits. In a
second shell (still as root) configure the interface + routing:

```bash
# In-TUN addresses, matching iOS NEPacketTunnelNetworkSettings.
sudo ifconfig utunN 172.19.0.1 172.19.0.2 mtu 1500 up

# Route everything through the tunnel (/1 split is the standard
# "everything except a host-route to the gateway" trick).
sudo route -n add -net 0.0.0.0/1   172.19.0.2
sudo route -n add -net 128.0.0.0/1 172.19.0.2

# Point DNS at the in-TUN address; the fake-IP intercept answers it.
sudo networksetup -setdnsservers Wi-Fi 172.19.0.2
```

To verify:

```bash
# CN-bypass: should answer with a real CN IP (not 28.x.x.x).
dig @172.19.0.2 baidu.com +short

# Non-CN: should answer with a 28.x.x.x fake IP.
dig @172.19.0.2 github.com +short
```

`Ctrl-C` the harness: it stops tun2socks + engine, closes the utun fd
(kernel removes the interface), and exits. Restore your normal DNS:

```bash
sudo networksetup -setdnsservers Wi-Fi empty
```

## Inside a Tart VM

This is the recommended sandbox: SIP-disabled or not, the harness only
needs `sudo`, libc, and the standard `utun` ioctls. The host stays
clean. Bring the VM's networking up first; the harness assumes a
working uplink for the engine's outbound proxy + DNS upstream
resolution.

## What this does *not* test

The Swift glue — `PacketTunnelProvider` lifecycle, `NEPacketTunnelFlow`
backpressure, App Group seeding, the UI. Those are iOS-only and still
need a real device. Everything below the FFI boundary is exercised
identically to the iOS build.
