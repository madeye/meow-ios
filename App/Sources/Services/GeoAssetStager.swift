import CryptoKit
import Foundation
import MeowModels
import os

/// Copies the bundled GeoIP / ASN / geosite databases into
/// `AppGroup.meowConfigDir` on launch, and keeps them current across app
/// upgrades. The Rust engine reads them from that directory at
/// `meow_engine_start` — its own geodata updater is deliberately disabled in
/// the FFI to stay within the Network Extension memory budget (see
/// `engine.rs`), so this is the *only* thing that ever refreshes these files.
///
/// Every staged file is tracked in a small JSON manifest
/// (`geo-asset-manifest.json`, alongside the databases) recording, per file,
/// whether the app or the user owns it and a fingerprint of the bundled
/// asset that was last staged:
///
///   - Missing or zero-byte destination → always (re)staged from the bundle,
///     regardless of any prior provenance. An empty file has no user content
///     worth preserving.
///   - Existing nonzero destination with **no manifest entry** → a
///     pre-#292 install. No shipped code path lets a user supply their own
///     Country.mmdb / GeoLite2-ASN.mmdb / geosite.mrs (verified: no Settings
///     UI, no import flow — the only geo-related user surface is the
///     `geox-url:` fallback in `EffectiveConfigWriter`, which merely tells
///     the engine's own — disabled — downloader where to fetch from). So an
///     unmanifested nonzero file is a stale first-ever-staged bundled copy.
///     It is replaced once and recorded as `.bundled`, after which normal
///     version tracking takes over.
///   - Existing nonzero destination manifested `.bundled` → replaced
///     atomically (temp file + rename, same directory) only when the
///     bundled asset's hash has changed since the manifest was last written.
///     To avoid hashing multi-megabyte `.mmdb`/`.mrs` files on every launch,
///     the manifest caches the app version the hash was computed under; the
///     bundled asset is only re-hashed when that version differs from the
///     running app's.
///   - Existing nonzero destination manifested `.user` → never touched.
///     Nothing in the shipped app sets this provenance today, but the
///     manifest format supports it so a future user-override path (or
///     manual edit of the manifest) is respected rather than silently
///     overwritten.
enum GeoAssetStager {
    private static let log = Logger(subsystem: "com.tangzixiang.meow", category: "geo-asset-stager")

    /// File names that must match `meow_config::default_*_path` in the FFI.
    /// Changing any of these will break the engine's discovery; keep in
    /// sync with `App/Resources/GeoData/` and meow-rs.
    private static let assets: [String] = [
        "Country.mmdb",
        "GeoLite2-ASN.mmdb",
        "geosite.mrs",
    ]

    private static let manifestFileName = "geo-asset-manifest.json"

    enum Provenance: String, Codable {
        case bundled
        case user
    }

    struct ManifestEntry: Codable, Equatable {
        var provenance: Provenance
        /// Hex SHA-256 of the bundled asset as of the last time it was
        /// staged (or confirmed unchanged).
        var bundledHash: String
        /// `CFBundleShortVersionString+CFBundleVersion` cached alongside
        /// `bundledHash` so an unchanged app build never re-hashes the
        /// bundled file — only a version change triggers a re-check.
        var appVersion: String
    }

    struct Manifest: Codable {
        var entries: [String: ManifestEntry] = [:]
    }

    /// - Parameters:
    ///   - destDir: Directory staged assets live in. Defaults to the real
    ///     App Group config directory; tests inject a temp directory.
    ///   - sourceDir: When non-nil, bundled assets are read from this
    ///     directory instead of `Bundle.main` — how tests supply fixture
    ///     content. Production callers leave this `nil`.
    ///   - appVersion: Cheap fingerprint of "which build is running", used
    ///     to skip re-hashing unchanged bundled assets. Defaults to the
    ///     real app's `CFBundleShortVersionString`/`CFBundleVersion`.
    static func stageIfNeeded(
        destDir: URL = AppGroup.meowConfigDir,
        sourceDir: URL? = nil,
        appVersion: String = currentAppVersion(),
    ) {
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            log.error("create dest dir failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let manifestURL = destDir.appending(path: manifestFileName)
        var manifest = loadManifest(at: manifestURL)

        for name in assets {
            guard let src = sourceURL(for: name, sourceDir: sourceDir) else {
                log.error("bundle missing \(name, privacy: .public)")
                continue
            }
            let dest = destDir.appending(path: name)
            processAsset(name: name, src: src, dest: dest, manifest: &manifest, appVersion: appVersion)
        }

        saveManifest(manifest, to: manifestURL)
    }

    // MARK: - Per-asset staging

    private static func processAsset(
        name: String,
        src: URL,
        dest: URL,
        manifest: inout Manifest,
        appVersion: String,
    ) {
        guard fileSize(at: dest) > 0 else {
            // Missing or corrupt/zero-byte destination: nothing to preserve,
            // stage fresh regardless of any prior manifest entry.
            stageFresh(name: name, src: src, dest: dest, manifest: &manifest, appVersion: appVersion)
            return
        }

        guard let entry = manifest.entries[name] else {
            // Existing file predates the manifest. See the type-level doc
            // comment for why this is treated as an app-managed copy rather
            // than a user override.
            log.notice("migrating unmanifested \(name, privacy: .public) to app-managed")
            stageFresh(name: name, src: src, dest: dest, manifest: &manifest, appVersion: appVersion)
            return
        }

        guard entry.provenance == .bundled else {
            log.notice("skipping user-managed \(name, privacy: .public)")
            return
        }

        guard entry.appVersion != appVersion else {
            // Same build we last checked under — the bundled asset can't
            // have changed without a new build. Skip hashing entirely.
            return
        }

        guard let bundledHash = try? sha256Hex(of: src) else {
            log.error("hash bundled \(name, privacy: .public) failed")
            return
        }

        guard bundledHash != entry.bundledHash else {
            // Bundle content is unchanged despite the version bump — just
            // refresh the cached version so we don't re-hash again until
            // the *next* version bump.
            manifest.entries[name]?.appVersion = appVersion
            return
        }

        do {
            try atomicReplace(src: src, dest: dest)
            manifest.entries[name] = ManifestEntry(
                provenance: .bundled, bundledHash: bundledHash, appVersion: appVersion,
            )
            log.notice("upgraded \(name, privacy: .public)")
        } catch {
            log.error("upgrade \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func stageFresh(
        name: String,
        src: URL,
        dest: URL,
        manifest: inout Manifest,
        appVersion: String,
    ) {
        do {
            let bundledHash = try sha256Hex(of: src)
            try atomicReplace(src: src, dest: dest)
            manifest.entries[name] = ManifestEntry(
                provenance: .bundled, bundledHash: bundledHash, appVersion: appVersion,
            )
            log.notice("staged \(name, privacy: .public)")
        } catch {
            log.error("stage \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies `src` to a temp file in `dest`'s own directory, then renames
    /// it over `dest`. Same-directory temp + rename keeps the swap atomic
    /// (single filesystem, single `rename()` syscall under the hood) so a
    /// reader never observes a partially-written destination file.
    private static func atomicReplace(src: URL, dest: URL) throws {
        let tmp = dest.deletingLastPathComponent()
            .appending(path: ".\(dest.lastPathComponent).staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    // MARK: - Sources

    private static func sourceURL(for name: String, sourceDir: URL?) -> URL? {
        if let sourceDir {
            let url = sourceDir.appending(path: name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "GeoData")
            ?? Bundle.main.url(forResource: name, withExtension: nil)
    }

    static func currentAppVersion(bundle: Bundle = .main) -> String {
        let short = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
        let build = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return "\(short)+\(build)"
    }

    // MARK: - Manifest persistence

    private static func loadManifest(at url: URL) -> Manifest {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            return Manifest()
        }
        return manifest
    }

    private static func saveManifest(_ manifest: Manifest, to url: URL) {
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("write manifest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Filesystem helpers

    private static func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
