import Foundation

/// Converts a raw subscription body (potentially base64-wrapped v2rayN URIs)
/// into a Clash YAML document. The production implementation calls into the
/// Go `meowConvertSubscription` FFI; tests can inject a pure-Swift stub.
protocol SubscriptionConverter: Sendable {
    func convert(_ body: Data) async throws -> String
}

/// Placeholder until the Go XCFramework is linked. Returns a minimal YAML
/// shell so development can proceed without the native binary in place.
struct GoSubscriptionConverter: SubscriptionConverter {
    func convert(_ body: Data) async throws -> String {
        #if MIHOMO_GO_LINKED
        return try MihomoGoBridge.convertSubscription(body)
        #else
        // Shell conversion keeps the type-check flow unblocked until the Go
        // XCFramework is built and linked.
        return """
        # Converted via Swift placeholder — replace with Go FFI once linked.
        proxies: []
        proxy-groups:
          - name: Proxy
            type: select
            proxies: []
        rules:
          - MATCH,Proxy
        """
        #endif
    }
}
