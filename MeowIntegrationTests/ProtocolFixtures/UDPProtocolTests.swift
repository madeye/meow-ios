import Foundation
import Testing

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
/// receive through these three adapters end-to-end. When T2.9 lands,
/// drop the `.disabled` attribute on each `@Test` below and stand up
/// WireGuard/Hysteria2/TUIC fixtures locally before running.
///
/// The automated fixture orchestration that previously lived in
/// `scripts/test-e2e-ios.sh` was retired in v1.4 (user directive,
/// 2026-04-18). Fixtures must be brought up manually — e.g. via
/// `wireguard-go`, `hysteria`, and `tuic-server` installed through
/// Homebrew — for on-demand local validation.
///
/// `.serialized` is required — the engine is a process singleton.
@Suite("UDP-backed protocol fixtures", .tags(.udpProtocols), .serialized)
struct UDPProtocolTests {
    // MARK: WireGuard

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `WireGuard: Noise IK handshake completes against wireguard-go fixture`() throws {
        try drive(proxy: "meow-fixture-wg", assertion: .handshake)
    }

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `WireGuard: HTTP 204 round-trip through tunnel`() throws {
        try drive(proxy: "meow-fixture-wg", assertion: .http204)
    }

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `WireGuard: DoH resolves via engine, not system resolver`() throws {
        try drive(proxy: "meow-fixture-wg", assertion: .dohThroughTunnel)
    }

    // MARK: Hysteria2

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `Hysteria2: QUIC + password auth completes`() throws {
        try drive(proxy: "meow-fixture-hy2", assertion: .handshake)
    }

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `Hysteria2: HTTP 204 round-trip through tunnel`() throws {
        try drive(proxy: "meow-fixture-hy2", assertion: .http204)
    }

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `Hysteria2: DoH resolves via engine, not system resolver`() throws {
        try drive(proxy: "meow-fixture-hy2", assertion: .dohThroughTunnel)
    }

    // MARK: TUIC

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `TUIC: UUID+password auth over QUIC completes`() throws {
        try drive(proxy: "meow-fixture-tuic", assertion: .handshake)
    }

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `TUIC: HTTP 204 round-trip through tunnel`() throws {
        try drive(proxy: "meow-fixture-tuic", assertion: .http204)
    }

    @Test(
        .disabled("blocked on T2.9"),
    )
    func `TUIC: DoH resolves via engine, not system resolver`() throws {
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

private func drive(proxy _: String, assertion _: FixtureAssertion) throws {
    Issue.record("drive(proxy:assertion:) not implemented — test should be skipped via .disabled until T2.9")
}
