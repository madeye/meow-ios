import Foundation
import MeowModels
import os
import Yams

/// Downloads the GeoIP/GeoSite/ASN MMDB databases declared in the effective
/// config's `geox-url:` block into `AppGroup.meowConfigDir` so meow-rs
/// finds them on disk at engine_start. meow-rs does NOT itself honor
/// `geox-url` for lazy fetching — the URL block tells the app where to
/// download from, and the app stages the files before the tunnel comes up.
///
/// Each URL maps to `<meowConfigDir>/<basename(url)>`. Files that already
/// exist with non-zero size are skipped (no HEAD revalidation — refresh
/// happens by deleting the file). Writes are atomic: download lands in a
/// `.partial` sibling and is renamed on success so a mid-transfer crash
/// never leaves a corrupted file for meow-rs to load.
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

    /// True when every URL in the user profile's `geox-url:` block already
    /// has a non-empty file in `meowConfigDir`. Used to decide whether the
    /// connect flow needs the proxy-bootstrap detour or can go straight to
    /// `startVPNTunnel` with the production config.
    static func allFilesPresent() -> Bool {
        let urls = geoXURLs(prefs: Preferences.load(from: AppGroup.defaults))
        guard !urls.isEmpty else { return true }
        for (_, source) in urls {
            let destination = AppGroup.meowConfigDir.appending(path: source.lastPathComponent)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            if size <= 0 { return false }
        }
        return true
    }

    /// Stage every URL listed in the effective config's `geox-url:` block —
    /// patched in-memory from the user's source profile so first connect
    /// works before the extension has ever written `effective-config.yaml`.
    /// Falls back to `defaultGeoXURL` when no source config exists yet
    /// (Settings → "Connect (no profile required)" debug path).
    ///
    /// `throughProxy` (when non-nil) routes the HTTPS download through a
    /// loopback proxy via `URLSession.connectionProxyDictionary`. Used by the
    /// in-process `BootstrapEngine`; see ADR-005.
    static func ensureFiles(prefs: Preferences, throughProxy proxy: URL? = nil) async throws {
        let urls = geoXURLs(prefs: prefs)
        guard !urls.isEmpty else { return }

        try FileManager.default.createDirectory(at: AppGroup.meowConfigDir, withIntermediateDirectories: true)

        let userOverridesGeoXURL = userProfileHasGeoXURL()

        for (name, sourceURL) in urls {
            let destination = AppGroup.meowConfigDir.appending(path: sourceURL.lastPathComponent)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
            if size > 0 { continue }

            let mirrors: [URL] = if userOverridesGeoXURL {
                [sourceURL]
            } else {
                (EffectiveConfigWriter.geoXMirrors[name] ?? [sourceURL.absoluteString]).compactMap(URL.init(string:))
            }
            try await downloadWithMirrors(name: name, mirrors: mirrors, to: destination, throughProxy: proxy)
        }
    }

    private static func userProfileHasGeoXURL() -> Bool {
        let source = (try? String(contentsOf: AppGroup.configURL, encoding: .utf8)) ?? ""
        let parsed = (try? Yams.load(yaml: source)) as? [String: Any]
        return parsed?["geox-url"] != nil
    }

    /// Recoverable URLError categories — connection-class failures we want to
    /// retry against the next mirror. Anything else (cancel, bad URL, server
    /// 5xx) propagates immediately.
    private static let mirrorRetryableCodes: Set<URLError.Code> = [
        .secureConnectionFailed,
        .cannotConnectToHost,
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .dnsLookupFailed,
    ]

    private static func downloadWithMirrors(
        name: String,
        mirrors: [URL],
        to destination: URL,
        throughProxy proxy: URL?,
    ) async throws {
        var lastError: Error?
        for (index, source) in mirrors.enumerated() {
            do {
                try await download(name: name, from: source, to: destination, throughProxy: proxy)
                if index > 0 {
                    log.notice("downloaded \(name, privacy: .public) from mirror #\(index, privacy: .public)")
                }
                return
            } catch let Failure.downloadFailed(_, underlying) where shouldRetry(underlying) {
                lastError = Failure.downloadFailed(name: name, underlying: underlying)
                continue
            } catch let httpError as Failure {
                if case .httpStatus = httpError {
                    lastError = httpError
                    continue
                }
                throw httpError
            } catch {
                throw error
            }
        }
        throw lastError ?? Failure.downloadFailed(name: name, underlying: URLError(.unknown))
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError, mirrorRetryableCodes.contains(urlError.code) {
            return true
        }
        return false
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

    private static func download(
        name: String,
        from source: URL,
        to destination: URL,
        throughProxy proxy: URL? = nil,
    ) async throws {
        log.info("downloading \(name, privacy: .public) from \(source.absoluteString, privacy: .public)")
        let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 180
            config.waitsForConnectivity = false
            if let proxy, let host = proxy.host, let port = proxy.port {
                // iOS has supported HTTPS-via-HTTP-proxy (CONNECT) since iOS 10.
                // The `HTTPSEnable/HTTPSProxy/HTTPSPort` keys are macOS-only in
                // SDK headers but are honored at runtime via untyped CFNetwork
                // string keys — the documented iOS workaround.
                // `NSAllowsLocalNetworking: true` in project.yml permits the
                // loopback hop.
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: true,
                    kCFNetworkProxiesHTTPProxy as String: host,
                    kCFNetworkProxiesHTTPPort as String: port,
                    "HTTPSEnable": true,
                    "HTTPSProxy": host,
                    "HTTPSPort": port,
                ]
            }
            return URLSession(configuration: config)
        }()
        defer { session.invalidateAndCancel() }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(from: source)
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
