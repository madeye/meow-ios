import Foundation
@testable import meow_ios
import SwiftData
import Testing

/// `SubscriptionService.addShadowsocks`: first add creates the generated
/// local profile, later adds re-render it in place, and a same-name add
/// replaces the earlier server. Uses the real template renderer + engine
/// validation end to end.
@Suite("Shadowsocks add service", .tags(.service))
struct ShadowsocksAddServiceTests {
    @MainActor
    private func makeService() throws -> (SubscriptionService, ModelContext) {
        let container = try ModelContainer(
            for: Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let context = ModelContext(container)
        return (SubscriptionService(modelContext: context), context)
    }

    private func server(name: String, host: String = "node.example.com", port: Int = 443) -> ShadowsocksServer {
        ShadowsocksServer(
            name: name,
            server: host,
            port: port,
            cipher: "aes-128-gcm",
            password: "pw-\(name)",
        )
    }

    @Test
    @MainActor
    func `first add creates a marked local profile`() throws {
        let (service, context) = try makeService()
        let profile = try service.addShadowsocks(server(name: "n1"))

        #expect(profile.url.isEmpty)
        #expect(ShadowsocksConfigBuilder.isGenerated(profile.yamlContent))
        #expect(ShadowsocksConfigBuilder.extractServers(from: profile.yamlContent).map(\.name) == ["n1"])
        #expect(try context.fetch(FetchDescriptor<Profile>()).count == 1)
    }

    @Test
    @MainActor
    func `second add accumulates into the same profile`() throws {
        let (service, context) = try makeService()
        let first = try service.addShadowsocks(server(name: "n1"))
        let second = try service.addShadowsocks(server(name: "n2", host: "10.1.2.3", port: 8388))

        #expect(first.id == second.id)
        #expect(try context.fetch(FetchDescriptor<Profile>()).count == 1)
        let names = ShadowsocksConfigBuilder.extractServers(from: second.yamlContent).map(\.name)
        #expect(names == ["n1", "n2"])
        // Previous rendering is preserved as the editor-revert backup.
        #expect(ShadowsocksConfigBuilder.extractServers(from: second.yamlBackup).map(\.name) == ["n1"])
    }

    @Test
    @MainActor
    func `same-name add replaces the earlier server`() throws {
        let (service, _) = try makeService()
        _ = try service.addShadowsocks(server(name: "n1", port: 443))
        let profile = try service.addShadowsocks(server(name: "n1", port: 8443))

        let servers = ShadowsocksConfigBuilder.extractServers(from: profile.yamlContent)
        #expect(servers.count == 1)
        #expect(servers.first?.port == 8443)
    }

    @Test
    @MainActor
    func `imported subscriptions are not mistaken for the generated profile`() throws {
        let (service, context) = try makeService()
        let imported = Profile(
            name: "Imported",
            url: "",
            yamlContent: "proxies:\n  - name: x\n    type: ss\n    server: a.example.com\n"
                + "    port: 443\n    cipher: aes-128-gcm\n    password: p\n",
        )
        context.insert(imported)
        try context.save()

        _ = try service.addShadowsocks(server(name: "n1"))
        let profiles = try context.fetch(FetchDescriptor<Profile>())
        #expect(profiles.count == 2)
        // The imported profile's YAML is untouched.
        #expect(ShadowsocksConfigBuilder.extractServers(from: imported.yamlContent).map(\.name) == ["x"])
    }
}
