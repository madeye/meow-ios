import Foundation
import SwiftData

/// Shared SwiftData container. Lives in the app's group container so the
/// extension can observe SwiftData changes via the same store — SwiftData
/// itself is app-only today, but keeping the file in the App Group paves the
/// way for read-access from the extension via the underlying SQLite file.
@MainActor
enum AppModelContainer {
    static let shared: AppModelContainer.Holder = {
        do {
            let schema = Schema([Profile.self, DailyTraffic.self])
            let url = try storeURL()
            resetStoreForUITestsIfRequested(at: url)
            let config = ModelConfiguration(
                "meow",
                schema: schema,
                url: url,
                cloudKitDatabase: .none,
            )
            let container = try ModelContainer(for: schema, configurations: config)
            seedProfileForUITestsIfRequested(container)
            seedScreenshotDemoIfRequested(container)
            return Holder(container: container)
        } catch {
            fatalError("Unable to open SwiftData store: \(error)")
        }
    }()

    struct Holder {
        let container: ModelContainer
    }

    /// `-ResetState` promises UI tests a known state, but it only reset the
    /// mock IPC snapshot — SwiftData profiles persisted across launches, so
    /// empty-state tests flaked on whatever earlier runs left behind. Wipe
    /// the store (and its SQLite sidecars) before the container opens it.
    private static func resetStoreForUITestsIfRequested(at url: URL) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-UITests"), args.contains("-ResetState") else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// `-SeedProfile <name>` inserts a single local profile so UI tests that
    /// act on an existing row (rename, delete, select) don't have to drive the
    /// add flow — whose password SecureField triggers an iOS "Save Password?"
    /// dialog that covers the list.
    private static func seedProfileForUITestsIfRequested(_ container: ModelContainer) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-UITests"), let idx = args.firstIndex(of: "-SeedProfile"),
              idx + 1 < args.count
        else { return }
        let name = args[idx + 1]
        let context = ModelContext(container)
        let profile = Profile(
            name: name,
            url: "",
            yamlContent: "proxies:\n  - name: seed\n    type: direct\n",
            yamlBackup: "proxies:\n  - name: seed\n    type: direct\n",
        )
        context.insert(profile)
        try? context.save()
    }

    /// `-ScreenshotDemo` populates the store for the App Store screenshot
    /// harness (scripts/capture-screenshots.sh): two subscription profiles
    /// (one selected, so the switch bar shows a name) and a week of daily
    /// traffic, so captures don't show fresh-install empty states.
    private static func seedScreenshotDemoIfRequested(_ container: ModelContainer) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-UITests"), args.contains("-ScreenshotDemo") else { return }
        let context = ModelContext(container)
        // The store persists across launches; without this guard every
        // relaunch of the harness stacks another duplicate demo profile.
        let seeded = (try? context.fetchCount(FetchDescriptor<Profile>())) ?? 0
        guard seeded == 0 else { return }
        context.insert(Profile(
            name: "Meow Cloud",
            url: "https://example.com/meow-cloud.yaml",
            yamlContent: screenshotDemoYAML,
            isSelected: true,
            lastUpdated: Date(timeIntervalSinceNow: -25 * 60),
            txBytes: 486_539_264,
            rxBytes: 3_842_146_304,
        ))
        context.insert(Profile(
            name: "Home Lab",
            url: "https://example.com/home-lab.yaml",
            yamlContent: screenshotDemoYAML,
            lastUpdated: Date(timeIntervalSinceNow: -2 * 86400),
        ))
        // Non-uniform but deterministic per-day bytes so the 7-day chart has
        // visible shape in every capture.
        let txMB: [Int64] = [148, 212, 96, 324, 187, 259, 173]
        let rxMB: [Int64] = [1120, 1730, 640, 2410, 1490, 2050, 1310]
        for i in 0 ..< 7 {
            guard let day = Calendar.current.date(byAdding: .day, value: -i, to: .now) else { continue }
            context.insert(DailyTraffic(
                date: DailyTraffic.key(for: day),
                txBytes: txMB[i] * 1_048_576,
                rxBytes: rxMB[i] * 1_048_576,
            ))
        }
        try? context.save()
    }

    /// Mirrors `MeowAPI.mockProxies()` so the seeded profiles stay plausible
    /// if anyone opens the YAML editor during a capture.
    private static let screenshotDemoYAML = """
    mode: rule
    proxies:
      - { name: "Tokyo 01", type: ss, server: tokyo.example.com, port: 8388, cipher: aes-256-gcm, password: demo }
      - name: "Singapore 02"
        type: vless
        server: sg.example.com
        port: 443
        uuid: 9f36c112-be0a-4b3c-9c5f-7d1f04d1a6e3
      - { name: "US West 03", type: trojan, server: us.example.com, port: 443, password: demo }
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Auto, "Tokyo 01", "Singapore 02", "US West 03"]
      - name: Auto
        type: url-test
        url: "http://www.gstatic.com/generate_204"
        interval: 300
        proxies: ["Tokyo 01", "Singapore 02", "US West 03"]
    rules:
      - MATCH,Proxy
    """

    private static func storeURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "meow")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dirURL = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? dirURL.setResourceValues(values)
        return dir.appending(path: "meow.sqlite")
    }
}
