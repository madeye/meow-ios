import Foundation
import SwiftData

/// A mihomo profile — either a fetched Clash YAML subscription or a manually
/// authored config.
@Model
final class Profile {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var yamlContent: String
    /// Pristine backup of the last imported YAML, used by the YAML editor's
    /// "Revert" action.
    var yamlBackup: String
    var isSelected: Bool
    var lastUpdated: Date
    var txBytes: Int64
    var rxBytes: Int64
    /// JSON-encoded `[groupName: proxyName]` — last manual selections restored
    /// on reconnect.
    var selectedProxiesJSON: String

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        yamlContent: String,
        yamlBackup: String = "",
        isSelected: Bool = false,
        lastUpdated: Date = .now,
        txBytes: Int64 = 0,
        rxBytes: Int64 = 0,
        selectedProxiesJSON: String = "{}"
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.yamlContent = yamlContent
        self.yamlBackup = yamlBackup.isEmpty ? yamlContent : yamlBackup
        self.isSelected = isSelected
        self.lastUpdated = lastUpdated
        self.txBytes = txBytes
        self.rxBytes = rxBytes
        self.selectedProxiesJSON = selectedProxiesJSON
    }

    var selectedProxies: [String: String] {
        get {
            guard let data = selectedProxiesJSON.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return map
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let s = String(data: data, encoding: .utf8) {
                selectedProxiesJSON = s
            }
        }
    }
}
