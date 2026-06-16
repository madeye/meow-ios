import Foundation
import MeowModels
import SwiftData
import Yams

/// Fetches and stores meow profiles. meow-rs only consumes Clash YAML
/// — if the subscription body isn't valid YAML it's rejected here rather
/// than producing a broken profile at engine startup.
@Observable
@MainActor
final class SubscriptionService {
    private let modelContext: ModelContext
    private let session: URLSession
    private let converter: SubscriptionConverter

    init(
        modelContext: ModelContext,
        session: URLSession = .shared,
        converter: SubscriptionConverter = ClashYAMLConverter(),
    ) {
        self.modelContext = modelContext
        self.session = session
        self.converter = converter
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, url: String) async throws -> Profile {
        let yaml = try await fetchAndNormalize(url: url)
        let profile = Profile(name: name, url: url, yamlContent: yaml, yamlBackup: yaml)
        modelContext.insert(profile)
        try modelContext.save()
        return profile
    }

    /// Import a profile from a local YAML payload (Files / iCloud Drive
    /// picker). No remote URL — `url` is empty, which the row UI uses to
    /// hide the refresh affordance.
    @discardableResult
    func addLocal(name: String, yamlContent: String) async throws -> Profile {
        let normalized = try await normalize(body: Data(yamlContent.utf8))
        let profile = Profile(name: name, url: "", yamlContent: normalized, yamlBackup: normalized)
        modelContext.insert(profile)
        try modelContext.save()
        return profile
    }

    func refresh(_ profile: Profile) async throws {
        guard !profile.url.isEmpty else { throw SubscriptionError.invalidURL }
        let yaml = try await fetchAndNormalize(url: profile.url)
        profile.yamlBackup = profile.yamlContent
        profile.yamlContent = yaml
        profile.lastUpdated = .now
        try modelContext.save()
    }

    func delete(_ profile: Profile) throws {
        modelContext.delete(profile)
        try modelContext.save()
    }

    /// Edit a profile's display name and update URL without touching its YAML
    /// body. A changed URL takes effect on the next `refresh(_:)` — the stored
    /// config is left as-is here. Attaching a URL to a previously local-only
    /// import (empty `url`) promotes it to a refreshable subscription.
    func updateInfo(_ profile: Profile, name: String, url: String) throws {
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        try modelContext.save()
    }

    func select(_ profile: Profile) throws {
        let fetch = FetchDescriptor<Profile>()
        let all = try modelContext.fetch(fetch)
        for p in all {
            p.isSelected = (p.id == profile.id)
        }
        AppGroup.defaults.set(profile.id.uuidString, forKey: PreferenceKey.selectedProfileID)
        try modelContext.save()
        try writeActiveConfig(profile)
    }

    func writeActiveConfig(_ profile: Profile) throws {
        let dir = AppGroup.containerURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try profile.yamlContent.write(to: AppGroup.configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Fetch + normalize

    private func fetchAndNormalize(url: String) async throws -> String {
        guard let remote = URL(string: url) else { throw SubscriptionError.invalidURL }
        var request = URLRequest(url: remote)
        // Most subscription panels gate the served proxy list on User-Agent —
        // generic clients see a CN-bypass-only YAML, Clash-family clients see
        // the full SS/Trojan/VLESS upstream set. Match exactly what the
        // embedded engine sends from its own subscription fetcher
        // (meow-rs `crates/meow-config/src/subscription.rs`:
        //   `concat!("clash.meta/", env!("CARGO_PKG_VERSION"))`),
        // so app-side refresh and engine-side rule-provider / geodata pulls
        // hit identical UA gates. Bumped together with the meow-rs tag
        // in `core/rust/meow-ios-ffi/Cargo.toml`.
        request.setValue("clash.meta/0.7.4", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw SubscriptionError.http(status: http.statusCode)
        }
        return try await normalize(body: data)
    }

    /// Internal-for-tests: runs the YAML sniff + optional conversion.
    func normalize(body: Data) async throws -> String {
        if SubscriptionParser.looksLikeClashYAML(body) {
            guard let text = String(data: body, encoding: .utf8) else {
                throw SubscriptionError.decodeFailed
            }
            // Round-trip through Yams to fail fast on bad YAML.
            _ = try Yams.load(yaml: text)
            return text
        }
        return try await converter.convert(body)
    }
}

enum SubscriptionError: Error {
    case invalidURL
    case http(status: Int)
    case decodeFailed
    case conversionFailed(String)
}

enum SubscriptionFormat {
    case clashYaml
    case v2rayN
}

enum SubscriptionParser {
    static func detectFormat(_ data: Data) -> SubscriptionFormat? {
        if looksLikeClashYAML(data) { return .clashYaml }
        if looksLikeV2RayN(data) { return .v2rayN }
        return nil
    }

    static func looksLikeClashYAML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text
            .split(whereSeparator: \.isNewline)
            .contains { line in
                guard line.first?.isWhitespace != true else { return false }
                let text = String(line).trimmingCharacters(in: .whitespaces)
                return isTopLevelYAMLKey("proxies:", line: text) ||
                    isTopLevelYAMLKey("proxy-groups:", line: text)
            }
    }

    static func looksLikeV2RayN(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let compact = text.filter { !$0.isWhitespace }
        // STANDARD_NO_PAD equivalent in Swift is a bit tricky with Data(base64Encoded:),
        // but it usually handles missing padding if we add it back.
        var b64 = compact
        while b64.count % 4 != 0 {
            b64.append("=")
        }
        if let decodedData = Data(base64Encoded: b64),
           let decodedText = String(data: decodedData, encoding: .utf8),
           decodedText.contains("://")
        {
            return true
        }
        return text.contains("ss://") || text.contains("trojan://") ||
            text.contains("vless://") || text.contains("vmess://")
    }

    private static func isTopLevelYAMLKey(_ key: String, line: String) -> Bool {
        line == key || line.hasPrefix("\(key) ")
    }
}

enum YamlPatcher {
    private static let defaultDNSPort: Int32 = 1053

    static func applyMixedPort(_ yaml: String, port: Int) throws -> String {
        try yaml.withCString { src -> String in
            let needed = meow_patch_config(src, Int32(port), 0, defaultDNSPort, nil, 0)
            if needed < 0 {
                throw SubscriptionError.conversionFailed(lastCoreError())
            }
            let cap = Int(needed) + 1
            var buffer = [CChar](repeating: 0, count: cap)
            let wrote = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                meow_patch_config(src, Int32(port), 0, defaultDNSPort, buf.baseAddress, Int32(cap))
            }
            if wrote < 0 {
                throw SubscriptionError.conversionFailed(lastCoreError())
            }
            return String(cString: buffer)
        }
    }
}

private func lastCoreError() -> String {
    if let cstr = meow_core_last_error() { return String(cString: cstr) }
    return "unknown error"
}
