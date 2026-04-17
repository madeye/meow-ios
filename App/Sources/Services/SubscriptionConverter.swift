import Foundation
import Yams

/// Normalizes a raw subscription body into Clash YAML. mihomo-rust only
/// consumes Clash YAML, so non-YAML formats (v2rayN base64 URI lists,
/// sing-box JSON, etc.) are rejected here rather than silently producing a
/// broken config. Tests inject a stub to simulate fetch responses without
/// hitting the network.
protocol SubscriptionConverter: Sendable {
    func convert(_ body: Data) async throws -> String
}

/// Default converter: decodes UTF-8 and validates it's parseable YAML. Real
/// conversion from provider-specific URI schemes belongs upstream in
/// mihomo-rust once it lands there.
struct ClashYAMLConverter: SubscriptionConverter {
    func convert(_ body: Data) async throws -> String {
        guard let text = String(data: body, encoding: .utf8) else {
            throw SubscriptionError.decodeFailed
        }
        do {
            _ = try Yams.load(yaml: text)
        } catch {
            throw SubscriptionError.conversionFailed(
                "subscription is not Clash YAML (\(error.localizedDescription))"
            )
        }
        return text
    }
}
