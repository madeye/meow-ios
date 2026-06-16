import Foundation
import Yams

/// Read + write the `rules:` block of a Clash YAML config without touching
/// any other top-level keys, comments aside (Yams round-trips through a
/// model so trailing-comment fidelity is lost — that's a documented
/// limitation, not unique to this editor; the config patcher already performs
/// the same YAML round-trip on the same source YAML and the shipping behaviour
/// treats that as acceptable).
///
/// Each rule in the YAML is a single string, either:
///
///   - `TYPE,PAYLOAD,PROXY` — the common case (DOMAIN-SUFFIX, IP-CIDR, …).
///   - `MATCH,PROXY` — the catch-all fallback (no payload).
///   - `TYPE,PAYLOAD,PROXY,FLAG1[,FLAG2…]` — extras like `no-resolve`,
///     `src`, etc., used by IP-family rules.
///
/// We parse into `EditableRule`, mutate, and re-emit with `Yams.dump`. The
/// rules block is replaced wholesale; everything else in the source YAML
/// is preserved through Yams' loader semantics.
enum RulesYAMLEditor {
    /// Parse `rules:` out of a Clash YAML string. Returns an empty array
    /// when the source has no rules block (or has it but it's empty / not
    /// a sequence). Throws on YAML parse errors.
    static func load(from sourceYAML: String) throws -> [EditableRule] {
        let loaded = try Yams.load(yaml: sourceYAML)
        guard let root = loaded as? [String: Any] else { return [] }
        guard let raw = root["rules"] as? [Any] else { return [] }
        // SwiftData re-encodes `Yams` integer scalars as `Int`s and string
        // scalars as `String`s. A rule line is always a string in valid
        // Clash YAML; coerce defensively and skip anything else.
        return raw.compactMap { entry -> EditableRule? in
            if let s = entry as? String {
                return EditableRule(rawLine: s)
            }
            return nil
        }
    }

    /// Replace the `rules:` block in `sourceYAML` with `rules` and return
    /// the rewritten YAML. Other top-level keys are preserved.
    ///
    /// Stable key ordering (`sortKeys: true`) matches what
    /// the config patcher already does so the on-disk effective config diffs
    /// cleanly across edits.
    static func apply(_ rules: [EditableRule], to sourceYAML: String) throws -> String {
        let loaded = try Yams.load(yaml: sourceYAML)
        var root: [String: Any] = (loaded as? [String: Any]) ?? [:]
        root["rules"] = rules.map(\.rawLine)
        return try Yams.dump(object: root, sortKeys: true)
    }
}
