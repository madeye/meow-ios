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
