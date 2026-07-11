import Foundation
@testable import meow_ios
import Testing

/// `GeoAssetStager` is the only thing that ever refreshes the bundled
/// Country.mmdb / GeoLite2-ASN.mmdb / geosite.mrs on an existing install —
/// the Rust engine's own geodata updater is deliberately disabled to stay
/// within the Network Extension memory budget (issue #292). Each test
/// stands up its own temp "bundle" and "App Group" directory so nothing
/// touches the real `AppGroup.meowConfigDir` or `Bundle.main`.
@Suite("GeoAssetStager", .tags(.service))
struct GeoAssetStagerTests {
    /// Files `GeoAssetStager` knows how to stage. Kept in sync with the
    /// private `assets` list inside the stager itself.
    private static let assetNames = ["Country.mmdb", "GeoLite2-ASN.mmdb", "geosite.mrs"]

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "GeoAssetStagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes all three asset names into `dir` with `content`, so a run
    /// against `dir` as the `sourceDir` never logs a "bundle missing" for
    /// the files this test isn't focused on.
    private func writeBundle(at dir: URL, content: String) throws {
        for name in Self.assetNames {
            try content.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }
    }

    private func readManifest(in destDir: URL) -> GeoAssetStager.Manifest? {
        guard let data = try? Data(contentsOf: destDir.appending(path: "geo-asset-manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(GeoAssetStager.Manifest.self, from: data)
    }

    @Test
    func `first install stages every bundled asset into an empty dest dir`() throws {
        let bundleDir = makeTempDir()
        let destDir = makeTempDir()
        try writeBundle(at: bundleDir, content: "v1")

        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.0+1")

        for name in Self.assetNames {
            let staged = try String(contentsOf: destDir.appending(path: name), encoding: .utf8)
            #expect(staged == "v1")
        }
        let manifest = try #require(readManifest(in: destDir))
        for name in Self.assetNames {
            let entry = try #require(manifest.entries[name])
            #expect(entry.provenance == .bundled)
            #expect(entry.appVersion == "1.0+1")
        }
    }

    @Test
    func `unchanged bundle content is never rewritten, even across a version bump`() throws {
        let bundleDir = makeTempDir()
        let destDir = makeTempDir()
        try writeBundle(at: bundleDir, content: "same-content")

        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.0+1")
        let dest = destDir.appending(path: "Country.mmdb")
        let firstStagedAt = try #require(
            try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date,
        )

        // Re-run under the SAME version: should short-circuit before even
        // looking at file content (cheap-fingerprint path).
        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.0+1")
        // Re-run under a NEW version but with byte-identical bundle content:
        // hash matches, so still no rewrite — only the cached version moves.
        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.1+2")

        let lastModifiedAt = try #require(
            try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date,
        )
        #expect(firstStagedAt == lastModifiedAt)

        let manifest = try #require(readManifest(in: destDir))
        let entry = try #require(manifest.entries["Country.mmdb"])
        #expect(entry.appVersion == "1.1+2")
    }

    @Test
    func `upgraded bundle content replaces the app-managed destination`() throws {
        let bundleDir = makeTempDir()
        let destDir = makeTempDir()
        try writeBundle(at: bundleDir, content: "v1")
        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.0+1")

        // Ship a new build with newer bundled content.
        try writeBundle(at: bundleDir, content: "v2-newer-geodata")
        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.1+2")

        for name in Self.assetNames {
            let staged = try String(contentsOf: destDir.appending(path: name), encoding: .utf8)
            #expect(staged == "v2-newer-geodata")
        }
        let manifest = try #require(readManifest(in: destDir))
        let entry = try #require(manifest.entries["Country.mmdb"])
        #expect(entry.appVersion == "1.1+2")
    }

    @Test
    func `corrupt zero-byte destination is re-staged regardless of manifest state`() throws {
        let bundleDir = makeTempDir()
        let destDir = makeTempDir()
        try writeBundle(at: bundleDir, content: "v1")
        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.0+1")

        // Simulate corruption: truncate one staged file to zero bytes, but
        // leave its manifest entry (and cached version) untouched — the
        // cheap-fingerprint short-circuit must not win over an empty file.
        try Data().write(to: destDir.appending(path: "Country.mmdb"))
        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.0+1")

        let staged = try String(contentsOf: destDir.appending(path: "Country.mmdb"), encoding: .utf8)
        #expect(staged == "v1")
    }

    @Test
    func `user-managed provenance is preserved even when the bundle changes`() throws {
        let bundleDir = makeTempDir()
        let destDir = makeTempDir()
        try writeBundle(at: bundleDir, content: "v1")

        // Simulate a user-supplied override recorded in the manifest ahead
        // of time (no shipped UI does this today; the format supports it).
        try "user-supplied-content".write(
            to: destDir.appending(path: "Country.mmdb"), atomically: true, encoding: .utf8,
        )
        var manifest = GeoAssetStager.Manifest()
        manifest.entries["Country.mmdb"] = GeoAssetStager.ManifestEntry(
            provenance: .user, bundledHash: "irrelevant", appVersion: "0.0+0",
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: destDir.appending(path: "geo-asset-manifest.json"))

        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.1+2")

        let staged = try String(contentsOf: destDir.appending(path: "Country.mmdb"), encoding: .utf8)
        #expect(staged == "user-supplied-content")
        let after = try #require(readManifest(in: destDir))
        #expect(after.entries["Country.mmdb"]?.provenance == .user)
    }

    @Test
    func `legacy unmanifested nonzero file is migrated to app-managed and staged once`() throws {
        let bundleDir = makeTempDir()
        let destDir = makeTempDir()
        try writeBundle(at: bundleDir, content: "v2-newer-geodata")

        // Simulate a pre-#292 install: a nonzero destination file with no
        // manifest at all (the old "any nonzero file wins" behavior never
        // wrote one).
        try "stale-first-ever-staged-copy".write(
            to: destDir.appending(path: "Country.mmdb"), atomically: true, encoding: .utf8,
        )

        GeoAssetStager.stageIfNeeded(destDir: destDir, sourceDir: bundleDir, appVersion: "1.1+2")

        let staged = try String(contentsOf: destDir.appending(path: "Country.mmdb"), encoding: .utf8)
        #expect(staged == "v2-newer-geodata")
        let manifest = try #require(readManifest(in: destDir))
        #expect(manifest.entries["Country.mmdb"]?.provenance == .bundled)
    }
}
