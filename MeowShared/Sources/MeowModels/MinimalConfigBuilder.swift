import Foundation
import Yams

/// Produces a bootstrap config containing only the user's first proxy plus a
/// catch-all `MATCH,<first-proxy>` rule. The app uses this to bring the
/// tunnel up briefly so it can download GeoIP/ASN databases through the
/// proxy — the production config can't start until the geo files are on
/// disk, but the geo file CDNs (jsDelivr) are often unreachable directly
/// from mainland China. Routing through one already-trusted proxy is the
/// cheapest way to break the chicken-and-egg.
///
/// The minimal config deliberately omits `geox-url`, `rule-providers`,
/// `dns`, and everything else that would force the engine to touch the
/// network for anything other than the proxy itself.
public enum MinimalConfigBuilder {
    public enum BuildError: Error, LocalizedError {
        case noProxies

        public var errorDescription: String? {
            switch self {
            case .noProxies: "Profile has no proxies — cannot bootstrap geo download."
            }
        }
    }

    public static func build(sourceYAML: String) throws -> String {
        let loaded = try Yams.load(yaml: sourceYAML)
        let root = (loaded as? [String: Any]) ?? [:]
        let proxies = (root["proxies"] as? [[String: Any]]) ?? []
        guard let first = proxies.first, let name = first["name"] as? String, !name.isEmpty else {
            throw BuildError.noProxies
        }

        let minimal: [String: Any] = [
            "mixed-port": EffectiveConfigWriter.defaultMixedPort,
            "external-controller": EffectiveConfigWriter.defaultExternalController,
            "log-level": "warning",
            "proxies": [first],
            "rules": ["MATCH,\(name)"],
        ]
        return try Yams.dump(object: minimal, sortKeys: true)
    }
}
