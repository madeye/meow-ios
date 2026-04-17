import Foundation
import MeowModels
import SwiftData
import Yams

/// Fetches and stores mihomo profiles. mihomo-rust only consumes Clash YAML
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

    func refresh(_ profile: Profile) async throws {
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
        let (data, response) = try await session.data(from: remote)
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

enum SubscriptionParser {
    static func looksLikeClashYAML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let prefix = text.prefix(4096)
        return prefix.contains("proxies:") || prefix.contains("proxy-groups:")
    }
}
