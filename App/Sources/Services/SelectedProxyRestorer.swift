import Foundation

/// Replays persisted proxy-group selections after the engine starts. mihomo-rust
/// keeps proxy-group state in-memory only, so each connect re-issues every
/// `(group, proxy)` selection the user previously made on the active profile.
enum SelectedProxyRestorer {
    /// Calls `select` for every `(group, proxy)` entry in `selections`.
    /// Iteration is alphabetical by group name so callers (and tests) can
    /// reason about ordering. Returns two lists:
    ///
    /// - `stale`: the API responded with HTTP 4xx, meaning the group or proxy
    ///   no longer exists server-side. Caller should drop these from the
    ///   persisted map — a subscription refresh renamed or removed them.
    /// - `transient`: any other error (URLError, timeout, 5xx). The server
    ///   may not be reachable yet or may be temporarily unhappy. Caller MUST
    ///   NOT treat these as stale; wiping persisted selections on transient
    ///   errors is how #59 silently erased the user's picks.
    static func restore(
        selections: [String: String],
        select: @Sendable (String, String) async throws -> Void,
    ) async -> (stale: [String], transient: [String]) {
        var stale: [String] = []
        var transient: [String] = []
        for (group, proxy) in selections.sorted(by: { $0.key < $1.key }) {
            do {
                try await select(group, proxy)
            } catch let MihomoAPIError.http(status) where (400 ..< 500).contains(status) {
                stale.append(group)
            } catch {
                transient.append(group)
            }
        }
        return (stale, transient)
    }
}
