import Testing
import Foundation

/// End-to-end assertions for the three UDP-backed protocols in the
/// §6.3 protocol matrix: WireGuard, Hysteria2, TUIC. Each one exercises
/// the same three checks the SS/Trojan/VLESS/VMess tests cover:
///
///   1. Handshake completes (iOS client auths with the fixture server)
///   2. Data round-trip (HTTP 204 through the proxy, §6.2 budget)
///   3. DNS through tunnel (DoH via the engine resolves to a fixture IP)
///
/// All tests in this suite carry `.disabled("blocked on T2.9")`:
/// PRD v1.3 / PROJECT_PLAN.md T2.9 defers non-DNS UDP forwarding to
/// post-M1.5. Until `mihomo_tunnel::udp::handle_udp` is wired to
/// netstack-smoltcp's UDP socket surface, the engine cannot send or
/// receive through these three adapters end-to-end — even though the
/// fixture servers stand up cleanly and the Clash subscription wires
/// the proxy entries correctly. When T2.9 lands, drop the `.disabled`
/// attribute on each `@Test` below; no fixture changes are required
/// (see TEST_FIXTURES.md §6 P4).
///
/// The fixture bring-up lives in `scripts/test-e2e-ios.sh`
/// (`MEOW_FIXTURE_PROTOCOLS=wg,hy2,tuic`). The Swift harness that
/// loads the subscription and drives the proxy selection is shared
/// with the SS/Trojan tests — it lands with T4.2 Home Screen anchors.
///
/// `.serialized` is required — the engine is a process singleton.
@Suite("UDP-backed protocol fixtures", .tags(.udpProtocols), .serialized)
struct UDPProtocolTests {

    // MARK: WireGuard

    @Test(
        "WireGuard: Noise IK handshake completes against wireguard-go fixture",
        .disabled("blocked on T2.9")
    )
    func wireguardHandshake() throws {
        try drive(proxy: "meow-fixture-wg", assertion: .handshake)
    }

    @Test(
        "WireGuard: HTTP 204 round-trip through tunnel",
        .disabled("blocked on T2.9")
    )
    func wireguardHTTP204() throws {
        try drive(proxy: "meow-fixture-wg", assertion: .http204)
    }

    @Test(
        "WireGuard: DoH resolves via engine, not system resolver",
        .disabled("blocked on T2.9")
    )
    func wireguardDNS() throws {
        try drive(proxy: "meow-fixture-wg", assertion: .dohThroughTunnel)
    }

    // MARK: Hysteria2

    @Test(
        "Hysteria2: QUIC + password auth completes",
        .disabled("blocked on T2.9")
    )
    func hysteria2Handshake() throws {
        try drive(proxy: "meow-fixture-hy2", assertion: .handshake)
    }

    @Test(
        "Hysteria2: HTTP 204 round-trip through tunnel",
        .disabled("blocked on T2.9")
    )
    func hysteria2HTTP204() throws {
        try drive(proxy: "meow-fixture-hy2", assertion: .http204)
    }

    @Test(
        "Hysteria2: DoH resolves via engine, not system resolver",
        .disabled("blocked on T2.9")
    )
    func hysteria2DNS() throws {
        try drive(proxy: "meow-fixture-hy2", assertion: .dohThroughTunnel)
    }

    // MARK: TUIC

    @Test(
        "TUIC: UUID+password auth over QUIC completes",
        .disabled("blocked on T2.9")
    )
    func tuicHandshake() throws {
        try drive(proxy: "meow-fixture-tuic", assertion: .handshake)
    }

    @Test(
        "TUIC: HTTP 204 round-trip through tunnel",
        .disabled("blocked on T2.9")
    )
    func tuicHTTP204() throws {
        try drive(proxy: "meow-fixture-tuic", assertion: .http204)
    }

    @Test(
        "TUIC: DoH resolves via engine, not system resolver",
        .disabled("blocked on T2.9")
    )
    func tuicDNS() throws {
        try drive(proxy: "meow-fixture-tuic", assertion: .dohThroughTunnel)
    }
}

extension Tag {
    @Tag static var udpProtocols: Self
}

/// Shared driver stub. The real implementation lands alongside the T4.2
/// Home Screen harness — by the time T2.9 flips these tests on, the
/// driver will already exist because the SS/Trojan tests depend on it.
private enum FixtureAssertion {
    case handshake
    case http204
    case dohThroughTunnel
}

private func drive(proxy: String, assertion: FixtureAssertion) throws {
    Issue.record("drive(proxy:assertion:) not implemented — test should be skipped via .disabled until T2.9")
}
