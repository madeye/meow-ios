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
    /// Directory + file the active config is written to. Defaults to the
    /// real App Group container; tests inject a temporary directory so they
    /// never touch the shared container (see `SubscriptionServiceTests`).
    private let activeConfigDirectory: () -> URL
    private let activeConfigURL: () -> URL
    /// Suite the selected-profile preference is persisted to. Defaults to
    /// the App Group suite; injectable for the same reason as above.
    private let preferences: UserDefaults

    init(
        modelContext: ModelContext,
        session: URLSession = .shared,
        converter: SubscriptionConverter = ClashYAMLConverter(),
        activeConfigDirectory: @escaping () -> URL = { AppGroup.containerURL },
        activeConfigURL: @escaping () -> URL = { AppGroup.configURL },
        preferences: UserDefaults = AppGroup.defaults,
    ) {
        self.modelContext = modelContext
        self.session = session
        self.converter = converter
        self.activeConfigDirectory = activeConfigDirectory
        self.activeConfigURL = activeConfigURL
        self.preferences = preferences
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

    /// Add a manually-entered / QR-scanned Shadowsocks server. Servers live
    /// in a single locally generated profile (rendered from the built-in
    /// template): the first add creates it, later adds re-render it with the
    /// accumulated server list. A server whose name matches an existing one
    /// replaces it. The rendered YAML is engine-validated before anything is
    /// persisted.
    @discardableResult
    func addShadowsocks(_ server: ShadowsocksServer) throws -> Profile {
        let all = try modelContext.fetch(FetchDescriptor<Profile>())
        let generated = all.first { ShadowsocksConfigBuilder.isGenerated($0.yamlContent) }

        var servers = generated.map { ShadowsocksConfigBuilder.extractServers(from: $0.yamlContent) } ?? []
        servers.removeAll { $0.name == server.name }
        servers.append(server)

        let yaml = try ShadowsocksConfigBuilder.render(servers: servers)
        try MeowConfigValidator.validate(yaml)

        if let generated {
            try updateContent(generated, yaml: yaml, lastUpdated: .now)
            return generated
        }
        let name = String(
            localized: "ssAdd.profile.defaultName",
            comment: "Name of the auto-created profile holding manually added Shadowsocks servers",
        )
        let profile = Profile(name: name, url: "", yamlContent: yaml, yamlBackup: yaml)
        modelContext.insert(profile)
        try modelContext.save()
        return profile
    }

    /// Refetch `profile`'s remote body and persist it. If `profile` is the
    /// selected profile, atomically refreshes the active config file too —
    /// refreshing an inactive profile only updates SwiftData.
    func refresh(_ profile: Profile) async throws {
        guard !profile.url.isEmpty else { throw SubscriptionError.invalidURL }
        let yaml = try await fetchAndNormalize(url: profile.url)
        try updateContent(profile, yaml: yaml, lastUpdated: .now)
    }

    /// Deletes `profile`. If it was the selected profile, this clears the
    /// selected-profile preference and removes the active config file
    /// rather than guessing a replacement — `writeEffectiveConfigWithPrefs`
    /// (`PacketTunnel/Sources/MWTunnelEngine.m`) already fails coherently
    /// (returns an error, doesn't crash) when `config.yaml` is absent, and
    /// every "current selection" query in the UI (`SubscriptionsView`,
    /// `HomeView`, `RulesView`, `ProxyGroupsView`, `GlobalVpnSwitchBar`)
    /// already renders an empty/no-selection state when `isSelected` matches
    /// nothing, so "no profile selected" is a well-supported state rather
    /// than an edge case to special-case around.
    func delete(_ profile: Profile) throws {
        let wasSelected = profile.isSelected
        if wasSelected {
            let previousPreference = preferences.string(forKey: PreferenceKey.selectedProfileID)
            preferences.removeObject(forKey: PreferenceKey.selectedProfileID)
            do {
                try clearActiveConfig()
            } catch {
                // Active file couldn't be cleared — restore the preference and
                // leave the profile in place rather than deleting it out from
                // under a `config.yaml` that still references it.
                if let previousPreference {
                    preferences.set(previousPreference, forKey: PreferenceKey.selectedProfileID)
                }
                throw error
            }
        }
        modelContext.delete(profile)
        try modelContext.save()
    }

    /// Edit a profile's display name and update URL without touching its YAML
    /// body. A changed URL takes effect on the next `refresh(_:)` — the stored
    /// config is left as-is here. Attaching a URL to a previously local-only
    /// import (empty `url`) promotes it to a refreshable subscription.
    func updateInfo(_ profile: Profile, name: String, url: String) throws {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            try Self.rejectPlainHTTP(trimmedURL)
        }
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.url = trimmedURL
        try modelContext.save()
    }

    func select(_ profile: Profile) throws {
        let fetch = FetchDescriptor<Profile>()
        let all = try modelContext.fetch(fetch)
        let previousSelectedIDs = Set(all.filter(\.isSelected).map(\.id))
        let previousPreference = preferences.string(forKey: PreferenceKey.selectedProfileID)
        for p in all {
            p.isSelected = (p.id == profile.id)
        }
        preferences.set(profile.id.uuidString, forKey: PreferenceKey.selectedProfileID)
        do {
            try modelContext.save()
            try writeActiveConfig(profile)
        } catch {
            for p in all {
                p.isSelected = previousSelectedIDs.contains(p.id)
            }
            if let previousPreference {
                preferences.set(previousPreference, forKey: PreferenceKey.selectedProfileID)
            } else {
                preferences.removeObject(forKey: PreferenceKey.selectedProfileID)
            }
            try? modelContext.save()
            throw error
        }
    }

    /// Persist a new YAML body for `profile` — from a subscription refresh
    /// or a manual YAML/rules edit — and, only when `profile` is currently
    /// selected, atomically rewrite the active config file to match. Editing
    /// or refreshing an inactive profile therefore never touches
    /// `config.yaml`. Rolls the SwiftData change back if the active-file
    /// write fails, so the two never diverge.
    func updateContent(_ profile: Profile, yaml: String, lastUpdated: Date? = nil) throws {
        let previousContent = profile.yamlContent
        let previousBackup = profile.yamlBackup
        let previousLastUpdated = profile.lastUpdated
        profile.yamlBackup = profile.yamlContent
        profile.yamlContent = yaml
        if let lastUpdated {
            profile.lastUpdated = lastUpdated
        }
        do {
            try modelContext.save()
            if profile.isSelected {
                try writeActiveConfig(profile)
            }
        } catch {
            profile.yamlContent = previousContent
            profile.yamlBackup = previousBackup
            profile.lastUpdated = previousLastUpdated
            try? modelContext.save()
            throw error
        }
    }

    func writeActiveConfig(_ profile: Profile) throws {
        let dir = activeConfigDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try profile.yamlContent.write(to: activeConfigURL(), atomically: true, encoding: .utf8)
    }

    /// Removes the active config file, if present. Used when the selected
    /// profile is deleted so `config.yaml` never outlives its profile.
    func clearActiveConfig() throws {
        let url = activeConfigURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Fetch + normalize

    /// Rejects plain-http config URLs up front. ATS
    /// (`NSAllowsArbitraryLoads` = false in `App/Info.plist`) blocks
    /// cleartext HTTP in the app process, so the fetch could only ever fail
    /// with an opaque `NSURLError` — tell the user why instead.
    static func rejectPlainHTTP(_ url: String) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") {
            throw SubscriptionError.insecureHTTPURL
        }
    }

    private func fetchAndNormalize(url: String) async throws -> String {
        try Self.rejectPlainHTTP(url)
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

enum SubscriptionError: Error, Equatable {
    case invalidURL
    case insecureHTTPURL
    case http(status: Int)
    case decodeFailed
    case conversionFailed(String)
}

extension SubscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .insecureHTTPURL:
            String(
                localized: "subscriptions.error.plainHTTP",
                comment: "Shown when a config URL uses http:// — iOS ATS blocks cleartext connections",
            )
        case .invalidURL, .http, .decodeFailed, .conversionFailed:
            nil
        }
    }
}

enum SubscriptionFormat {
    case clashYaml
    case v2rayN
}

enum SubscriptionParser {
    static func detectFormat(_ data: Data) -> SubscriptionFormat? {
        if looksLikeClashYAML(data) {
            return .clashYaml
        }
        if looksLikeV2RayN(data) {
            return .v2rayN
        }
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
    if let cstr = meow_core_last_error() {
        return String(cString: cstr)
    }
    return "unknown error"
}
