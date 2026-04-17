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
            let config = ModelConfiguration(
                "meow",
                schema: schema,
                url: url,
                cloudKitDatabase: .none,
            )
            let container = try ModelContainer(for: schema, configurations: config)
            return Holder(container: container)
        } catch {
            fatalError("Unable to open SwiftData store: \(error)")
        }
    }()

    struct Holder {
        let container: ModelContainer
    }

    private static func storeURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "meow")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "meow.sqlite")
    }
}
