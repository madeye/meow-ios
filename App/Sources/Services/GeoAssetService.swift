import Foundation
import MeowModels
import os
import Yams

/// Downloads the GeoIP/GeoSite/ASN MMDB databases declared in the effective
/// config's `geox-url:` block into `AppGroup.mihomoConfigDir` so mihomo-rust
/// finds them on disk at engine_start. mihomo-rust does NOT itself honor
/// `geox-url` for lazy fetching — the URL block tells the app where to
/// download from, and the app stages the files before the tunnel comes up.
///
/// Each URL maps to `<mihomoConfigDir>/<basename(url)>`. Files that already
/// exist with non-zero size are skipped (no HEAD revalidation — refresh
/// happens by deleting the file). Writes are atomic: download lands in a
/// `.partial` sibling and is renamed on success so a mid-transfer crash
/// never leaves a corrupted file for mihomo-rust to load.
enum GeoAssetService {
    private static let log = Logger(subsystem: "io.github.madeye.meow", category: "geo-asset")

    enum Failure: LocalizedError {
        case downloadFailed(name: String, underlying: Error)
        case httpStatus(name: String, code: Int)

        var errorDescription: String? {
            switch self {
            case let .downloadFailed(name, underlying):
                "Failed to download \(name): \(underlying.localizedDescription)"
            case let .httpStatus(name, code):
                "Failed to download \(name) (HTTP \(code))"
            }
        }
    }

    /// Stage every URL listed in the effective config's `geox-url:` block —
    /// patched in-memory from the user's source profile so first connect
    /// works before the extension has ever written `effective-config.yaml`.
    /// Falls back to `defaultGeoXURL` when no source config exists yet
    /// (Settings → "Connect (no profile required)" debug path).
    static func ensureFiles(prefs: Preferences) async throws {
        let urls = geoXURLs(prefs: prefs)
        guard !urls.isEmpty else { return }

        try FileManager.default.createDirectory(at: AppGroup.mihomoConfigDir, withIntermediateDirectories: true)

        for (name, sourceURL) in urls {
            let destination = AppGroup.mihomoConfigDir.appending(path: sourceURL.lastPathComponent)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            if size > 0 { continue }
            try await download(name: name, from: sourceURL, to: destination)
        }
    }

    private static func geoXURLs(prefs: Preferences) -> [(name: String, url: URL)] {
        let source = (try? String(contentsOf: AppGroup.configURL, encoding: .utf8)) ?? ""
        let patched = (try? EffectiveConfigWriter.patch(sourceYAML: source, prefs: prefs)) ?? ""
        let parsed = (try? Yams.load(yaml: patched)) as? [String: Any]
        let geox = parsed?["geox-url"] as? [String: String] ?? EffectiveConfigWriter.defaultGeoXURL
        return geox.compactMap { key, value in
            guard let url = URL(string: value) else { return nil }
            return (name: key, url: url)
        }
    }

    private static func download(name: String, from source: URL, to destination: URL) async throws {
        log.info("downloading \(name, privacy: .public) from \(source.absoluteString, privacy: .public)")
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await URLSession.shared.download(from: source)
        } catch {
            throw Failure.downloadFailed(name: name, underlying: error)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw Failure.httpStatus(name: name, code: http.statusCode)
        }

        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: tempURL, to: partial)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
