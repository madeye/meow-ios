import Foundation

/// Replays persisted proxy-group selections after the engine starts. mihomo-rust
/// keeps proxy-group state in-memory only, so each connect re-issues every
/// `(group, proxy)` selection the user previously made on the active profile.
enum SelectedProxyRestorer {
    /// Calls `select` for every `(group, proxy)` entry in `selections`.
    /// Iteration is alphabetical by group name so callers (and tests) can
    /// reason about ordering. Returns the names of groups whose `select`
    /// closure threw — caller may use this list to drop stale entries from
    /// persistence (the proxy or the group disappeared after a refresh).
    static func restore(
        selections: [String: String],
        select: @Sendable (String, String) async throws -> Void,
    ) async -> [String] {
        var stale: [String] = []
        for (group, proxy) in selections.sorted(by: { $0.key < $1.key }) {
            do {
                try await select(group, proxy)
            } catch {
                stale.append(group)
            }
        }
        return stale
    }
}
