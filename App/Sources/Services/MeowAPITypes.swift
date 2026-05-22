import Foundation

struct Proxy: Decodable, Identifiable {
    var id: String {
        name
    }

    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let history: [History]?

    struct History: Decodable {
        let time: String
        let delay: Int
    }
}

struct ProxiesResponse: Decodable {
    let proxies: [String: Proxy]
}

struct Connection: Decodable, Identifiable {
    let id: String
    // meow-rs's `/connections` payload (meow-api routes.rs:281-289)
    // omits the per-connection metadata block today, so leave this optional.
    let metadata: Metadata?
    let upload: Int64
    let download: Int64
    let start: String
    let chains: [String]
    let rule: String
    let rulePayload: String

    struct Metadata: Decodable {
        let network: String
        let type: String
        let sourceIP: String
        let destinationIP: String
        let destinationPort: String
        let host: String
    }
}

struct ConnectionsResponse: Decodable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [Connection]?

    /// meow-rs serializes the outer struct fields with default snake_case
    /// (meow-api routes.rs:270-275 — no `rename_all` attribute) while the
    /// per-connection JSON is built with literal camelCase keys.
    enum CodingKeys: String, CodingKey {
        case downloadTotal = "download_total"
        case uploadTotal = "upload_total"
        case connections
    }
}

struct Rule: Decodable, Identifiable {
    var id: String {
        "\(type)\(payload)\(proxy)"
    }

    let type: String
    let payload: String
    let proxy: String
}

struct RulesResponse: Decodable {
    let rules: [Rule]
}

struct Provider: Decodable {
    let name: String
    let type: String
    let vehicleType: String?
    let proxies: [Proxy]?
}

struct ProvidersResponse: Decodable {
    let providers: [String: Provider]
}

struct ConfigsResponse: Decodable {
    let mode: String
}

struct LogEntry: Decodable {
    let type: String
    let payload: String

    static func from(jsonString: String) -> LogEntry? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LogEntry.self, from: data)
    }
}
