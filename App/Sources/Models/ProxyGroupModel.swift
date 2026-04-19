import MeowModels

/// View-model shape the proxy-groups section renders. Built from a mihomo
/// `/proxies` response via `build(from:)`, which filters to user-selectable
/// group types and projects each child proxy's most recent delay probe.
struct ProxyGroupModel: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let now: String?
    let children: [Child]

    struct Child: Identifiable, Equatable {
        let id: String
        let name: String
        let type: String
        let delay: Int?
    }

    /// Flatten the mihomo `/proxies` response into the subset of proxy groups
    /// the user can interact with. `GLOBAL` is hidden because it's the
    /// top-level aggregator, not a user-facing selector; direct/reject are
    /// leaf proxies, not groups.
    static func build(from dict: [String: Proxy]) -> [ProxyGroupModel] {
        let selectable: Set = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
        return dict.values
            .filter { selectable.contains($0.type) && $0.all != nil && $0.name != "GLOBAL" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { group in
                let children = (group.all ?? []).compactMap { childName -> Child? in
                    guard let p = dict[childName] else { return nil }
                    return Child(
                        id: childName,
                        name: p.name,
                        type: p.type,
                        delay: p.history?.last?.delay,
                    )
                }
                return ProxyGroupModel(
                    id: group.name,
                    name: group.name,
                    type: group.type,
                    now: group.now,
                    children: children,
                )
            }
    }
}
