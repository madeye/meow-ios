import Foundation
import MeowModels
import os

/// Copies the bundled GeoIP / ASN / geosite databases into
/// `AppGroup.meowConfigDir` on launch when they are absent there. The Rust
/// engine reads them from that directory at `meow_engine_start`, so staging
/// at app launch means the first connect never needs to download anything.
/// Files already on disk are left alone — re-running the stager does not
/// clobber a user's later overwrite or a meow-rs `geodata.auto-update`
/// refresh.
enum GeoAssetStager {
    private static let log = Logger(subsystem: "io.github.madeye.meow", category: "geo-asset-stager")

    /// File names that must match `meow_config::default_*_path` in the FFI.
    /// Changing any of these will break the engine's discovery; keep in
    /// sync with `App/Resources/GeoData/` and meow-rs.
    private static let assets: [String] = [
        "Country.mmdb",
        "GeoLite2-ASN.mmdb",
        "geosite.mrs",
    ]

    static func stageIfNeeded() {
        let destDir = AppGroup.meowConfigDir
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            log.error("create meowConfigDir failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        for name in assets {
            let dest = destDir.appending(path: name)
            let existingSize = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            if existingSize > 0 { continue }

            guard let src = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "GeoData")
                ?? Bundle.main.url(forResource: name, withExtension: nil)
            else {
                log.error("bundle missing \(name, privacy: .public)")
                continue
            }

            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
                log.notice("staged \(name, privacy: .public)")
            } catch {
                log.error(
                    "stage \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)",
                )
            }
        }
    }
}
