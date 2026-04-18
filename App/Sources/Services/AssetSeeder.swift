import Foundation
import MeowModels

/// Seeds the bundled `Country.mmdb` into the App Group container so
/// `mihomo-config::default_geoip_path()` resolves (via `XDG_CONFIG_HOME`) to
/// a real file on both the app and the extension's first launch. Idempotent —
/// it skips if the destination already matches the bundled size, and
/// overwrites on a mismatch so a refreshed bundle beats a stale seeded copy.
enum AssetSeeder {
    static func seedIfNeeded() async {
        guard let src = Bundle.main.url(forResource: "Country", withExtension: "mmdb") else {
            NSLog("AssetSeeder: Country.mmdb missing from app bundle — GEOIP lookups will fall back to geox-url")
            return
        }
        let dst = AppGroup.countryMmdbURL
        try? FileManager.default.createDirectory(at: AppGroup.mihomoConfigDir, withIntermediateDirectories: true)

        if let srcSize = fileSize(at: src), let dstSize = fileSize(at: dst), srcSize == dstSize {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            NSLog("AssetSeeder: failed to seed Country.mmdb: %@", String(describing: error))
        }
    }

    private static func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }
}
