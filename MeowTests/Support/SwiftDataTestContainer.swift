import Foundation
import SwiftData

/// Builds an in-memory ``ModelContainer`` seeded with the app's schema.
/// Unit tests that touch SwiftData should obtain a fresh container here and
/// never reach the shared App Group store.
///
/// Replace the schema types with the real `Profile` / `DailyTraffic` models
/// once T4.1 lands.
enum SwiftDataTestContainer {
    static func make() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // TODO: replace with actual schema once Profile/DailyTraffic are defined.
        let schema = Schema([])
        return try ModelContainer(for: schema, configurations: config)
    }
}
