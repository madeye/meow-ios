import Foundation
import MeowModels

/// Copies geoip/geosite/country databases from the app bundle into the App
/// Group container on first launch so both the app and the extension can
/// read them. Safe to call on every launch — it skips files that are already
/// in place.
enum AssetSeeder {
    private static let bundled: [(bundleName: String, destination: URL)] = [
        ("geoip", AppGroup.geoIPURL),
        ("geosite", AppGroup.geositeURL),
        ("country", AppGroup.countryURL),
    ]

    static func seedIfNeeded() async {
        try? FileManager.default.createDirectory(at: AppGroup.assetsDir, withIntermediateDirectories: true)
        for (name, dst) in bundled {
            guard !FileManager.default.fileExists(atPath: dst.path) else { continue }
            guard let src = urlForBundledAsset(named: name) else { continue }
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                NSLog("AssetSeeder: failed to copy %@: %@", name, String(describing: error))
            }
        }
    }

    private static func urlForBundledAsset(named name: String) -> URL? {
        let bundle = Bundle.main
        return bundle.url(forResource: name, withExtension: "metadb")
            ?? bundle.url(forResource: name, withExtension: "dat")
            ?? bundle.url(forResource: name, withExtension: "mmdb")
    }
}
