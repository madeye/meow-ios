import Foundation
import MeowModels
import os

/// Seeds the bundled GEOIP-class assets into the App Group container so the
/// engine's `XDG_CONFIG_HOME` resolution lands on real files on the first
/// launch of either the app or the extension. Each entry is idempotent — it
/// skips when the destination already matches the bundled size, and
/// overwrites on a mismatch so a refreshed bundle beats a stale seeded copy.
///
/// Current bundle:
///   • `Country.mmdb`  — GEOIP MMDB consumed by mihomo-config.
///   • `cn-ipv4.bin`   — packed CN IPv4 ranges read by the Rust FFI's
///                       `cn_iprange::load` for fake-IP CN bypass.
///   • `cn-ipv6.bin`   — companion IPv6 table.
enum AssetSeeder {
    private static let log = Logger(subsystem: "io.github.madeye.meow", category: "asset-seeder")

    private struct Asset {
        let bundleName: String
        let bundleExt: String
        let destination: URL
    }

    static func seedIfNeeded() async {
        try? FileManager.default.createDirectory(at: AppGroup.mihomoConfigDir, withIntermediateDirectories: true)

        let assets: [Asset] = [
            Asset(bundleName: "Country", bundleExt: "mmdb", destination: AppGroup.countryMmdbURL),
            Asset(bundleName: "cn-ipv4", bundleExt: "bin", destination: AppGroup.cnIpv4URL),
            Asset(bundleName: "cn-ipv6", bundleExt: "bin", destination: AppGroup.cnIpv6URL),
        ]

        for asset in assets {
            seedOne(asset)
        }
    }

    private static func seedOne(_ asset: Asset) {
        guard let src = Bundle.main.url(forResource: asset.bundleName, withExtension: asset.bundleExt) else {
            log.error("\(asset.bundleName).\(asset.bundleExt, privacy: .public) missing from app bundle")
            return
        }

        let dst = asset.destination
        if let srcSize = fileSize(at: src), let dstSize = fileSize(at: dst), srcSize == dstSize {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            log.error(
                "failed to seed \(asset.bundleName, privacy: .public): \(String(describing: error), privacy: .public)",
            )
        }
    }

    private static func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }
}
