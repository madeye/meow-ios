package main

// installProtectHook is a no-op on iOS.
//
// On Android, VpnService.protect(fd) marks outbound sockets as excluded from
// the TUN so proxy traffic doesn't loop back through the tunnel. iOS
// NEPacketTunnelProvider handles this at the routing layer — sockets opened
// inside the extension are already excluded from the tunnel's default route
// by the system — so we deliberately leave dialer.DefaultSocketHook nil.
func installProtectHook() {}

// clearProtectHook matches the Android shape; nothing to do here.
func clearProtectHook() {}
