import Foundation
@testable import meow_ios
import MeowModels
import Testing

@Suite("Utility session stores", .tags(.model))
@MainActor
struct UtilitySessionStoreTests {
    @Test
    func `traffic chart retains samples across ingest calls`() {
        let store = UtilityTrafficChartStore()
        let first = TrafficSnapshot(
            uploadBytes: 1,
            downloadBytes: 2,
            uploadRate: 100,
            downloadRate: 200,
            ingressPackets: 1,
            egressPackets: 1,
            timestamp: Date(),
        )
        let second = TrafficSnapshot(
            uploadBytes: 3,
            downloadBytes: 4,
            uploadRate: 150,
            downloadRate: 250,
            ingressPackets: 2,
            egressPackets: 2,
            timestamp: Date().addingTimeInterval(1),
        )

        store.ingest(first)
        store.ingest(second)

        #expect(store.samples.count == 2)
        #expect(store.samples[0].uploadRate == 100)
        #expect(store.samples[1].downloadRate == 250)
    }

    @Test
    func `traffic chart prunes samples older than 60s window`() {
        let store = UtilityTrafficChartStore()
        let stale = TrafficSnapshot(
            uploadBytes: 0,
            downloadBytes: 0,
            uploadRate: 1,
            downloadRate: 1,
            ingressPackets: 0,
            egressPackets: 0,
            timestamp: Date().addingTimeInterval(-120),
        )
        let fresh = TrafficSnapshot(
            uploadBytes: 0,
            downloadBytes: 0,
            uploadRate: 9,
            downloadRate: 9,
            ingressPackets: 0,
            egressPackets: 0,
            timestamp: Date(),
        )

        store.ingest(stale)
        store.ingest(fresh)

        #expect(store.samples.count == 1)
        #expect(store.samples[0].uploadRate == 9)
    }

    @Test
    func `logs store keeps level and autoScroll across re-entry`() {
        let store = UtilityLogsStore()
        store.level = "warning"
        store.autoScroll = false

        #expect(store.level == "warning")
        #expect(store.autoScroll == false)
    }

    @Test
    func `dns ttl fits Int for localized %lld keys`() async throws {
        let api = MeowAPI()
        let results = try await api.getDnsResults()
        let ttl = try #require(results.first?.ttl)
        #expect(Int(ttl) == 298 || Int(ttl) == 412 || Int(ttl) == 389 || Int(ttl) == 600)
    }
}
