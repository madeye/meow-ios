import Foundation
@testable import meow_ios
import SwiftData
import Testing

/// `ProfileAutoUpdater` decides *which* profiles are stale (the pure
/// `isDue`/`dueProfiles` policy) and then hands each one to
/// `SubscriptionService.refresh(_:)`. Both halves are covered here: the policy
/// against a frozen clock, and the pass itself against stubbed HTTP.
///
/// The timer loop (`start()`/`stop()`) is deliberately untested — it only
/// sleeps and calls `refreshDueProfiles()`, and a 30-minute tick can't be
/// exercised without either a fake clock abstraction or a real wait.
@Suite("ProfileAutoUpdater", .tags(.service))
struct ProfileAutoUpdaterTests {
    // MARK: - Cadence policy

    @Test
    @MainActor
    func `a manual profile is never due, however stale`() {
        let now = Date()
        let profile = makeProfile(interval: .manual, lastUpdated: now.addingTimeInterval(-365 * 86400))
        #expect(!ProfileAutoUpdater.isDue(profile, at: now))
    }

    @Test
    @MainActor
    func `a daily profile comes due exactly one day after its last update`() {
        let now = Date()
        let justUnder = makeProfile(interval: .daily, lastUpdated: now.addingTimeInterval(-86399))
        let exactly = makeProfile(interval: .daily, lastUpdated: now.addingTimeInterval(-86400))
        let wellOver = makeProfile(interval: .daily, lastUpdated: now.addingTimeInterval(-3 * 86400))

        #expect(!ProfileAutoUpdater.isDue(justUnder, at: now))
        #expect(ProfileAutoUpdater.isDue(exactly, at: now))
        #expect(ProfileAutoUpdater.isDue(wellOver, at: now))
    }

    @Test
    @MainActor
    func `a weekly profile ignores the daily boundary and comes due after seven days`() {
        let now = Date()
        let twoDaysOld = makeProfile(interval: .weekly, lastUpdated: now.addingTimeInterval(-2 * 86400))
        let sevenDaysOld = makeProfile(interval: .weekly, lastUpdated: now.addingTimeInterval(-7 * 86400))

        #expect(!ProfileAutoUpdater.isDue(twoDaysOld, at: now))
        #expect(ProfileAutoUpdater.isDue(sevenDaysOld, at: now))
    }

    @Test
    @MainActor
    func `a local import is never due — there is no remote to refetch`() {
        let now = Date()
        let local = makeProfile(url: "", interval: .daily, lastUpdated: now.addingTimeInterval(-30 * 86400))
        #expect(!ProfileAutoUpdater.isDue(local, at: now))
    }

    @Test
    @MainActor
    func `a stamp in the future is due rather than frozen`() {
        // Only reachable via a device clock that was set forward and later
        // corrected. Refetching restamps `lastUpdated` to now, which unsticks
        // the cadence instead of stalling it until real time catches up.
        let now = Date()
        let skewed = makeProfile(interval: .daily, lastUpdated: now.addingTimeInterval(30 * 86400))
        #expect(ProfileAutoUpdater.isDue(skewed, at: now))
    }

    @Test
    @MainActor
    func `dueProfiles keeps only the stale ones`() {
        let now = Date()
        let stale = makeProfile(interval: .daily, lastUpdated: now.addingTimeInterval(-2 * 86400))
        let fresh = makeProfile(interval: .daily, lastUpdated: now.addingTimeInterval(-60))
        let manual = makeProfile(interval: .manual, lastUpdated: now.addingTimeInterval(-2 * 86400))

        let due = ProfileAutoUpdater.dueProfiles(in: [stale, fresh, manual], at: now)

        #expect(due.count == 1)
        #expect(due.first === stale)
    }

    // MARK: - A refresh pass

    @Test
    @MainActor
    func `a pass refetches the due profile and leaves the others alone`() async throws {
        let dueURL = "https://example.com/auto-due.yaml"
        let freshURL = "https://example.com/auto-fresh.yaml"
        let original = "proxies: []\n"
        let refreshed = "proxies:\n  - name: refreshed\n    type: direct\n"
        defer {
            URLProtocolStub.removeStub(URL(string: dueURL)!)
            URLProtocolStub.removeStub(URL(string: freshURL)!)
        }
        // Both URLs are stubbed, so "fresh wasn't refetched" is a real
        // assertion about the cadence rather than a missing-stub failure.
        let session = stubbedSession([
            dueURL: .init(body: Data(refreshed.utf8)),
            freshURL: .init(body: Data(refreshed.utf8)),
        ])

        let now = Date()
        let harness = try makeUpdater(now: now, session: session)
        let staleStamp = now.addingTimeInterval(-25 * 3600)
        let due = makeProfile(url: dueURL, interval: .daily, lastUpdated: staleStamp, yaml: original)
        let fresh = makeProfile(
            url: freshURL,
            interval: .daily,
            lastUpdated: now.addingTimeInterval(-60),
            yaml: original,
        )
        let manual = makeProfile(url: dueURL, interval: .manual, lastUpdated: staleStamp, yaml: original)
        for profile in [due, fresh, manual] {
            harness.context.insert(profile)
        }
        try harness.context.save()

        await harness.updater.refreshDueProfiles()

        #expect(due.yamlContent == refreshed)
        #expect(due.lastUpdated > staleStamp)
        #expect(fresh.yamlContent == original)
        #expect(manual.yamlContent == original)
        // Having been refetched, the profile is quiet again for a day — the
        // next pass an hour from now must not fetch it a second time.
        #expect(!ProfileAutoUpdater.isDue(due, at: due.lastUpdated.addingTimeInterval(3600)))
    }

    @Test
    @MainActor
    func `one failing subscription does not stop the others`() async throws {
        let brokenURL = "https://example.com/auto-broken.yaml"
        let goodURL = "https://example.com/auto-good.yaml"
        let original = "proxies: []\n"
        let refreshed = "proxies:\n  - name: refreshed\n    type: direct\n"
        defer {
            URLProtocolStub.removeStub(URL(string: brokenURL)!)
            URLProtocolStub.removeStub(URL(string: goodURL)!)
        }
        let session = stubbedSession([
            brokenURL: .init(statusCode: 500),
            goodURL: .init(body: Data(refreshed.utf8)),
        ])

        let now = Date()
        let harness = try makeUpdater(now: now, session: session)
        let staleStamp = now.addingTimeInterval(-8 * 86400)
        let broken = makeProfile(url: brokenURL, interval: .daily, lastUpdated: staleStamp, yaml: original)
        let good = makeProfile(url: goodURL, interval: .weekly, lastUpdated: staleStamp, yaml: original)
        harness.context.insert(broken)
        harness.context.insert(good)
        try harness.context.save()

        // The pass must not rethrow — an HTTP 500 on one profile is logged and
        // skipped, not escalated.
        await harness.updater.refreshDueProfiles()

        #expect(good.yamlContent == refreshed)
        #expect(broken.yamlContent == original)
        // `lastUpdated` only advances on success, so the failed profile is
        // still due and gets retried on the next pass.
        #expect(broken.lastUpdated < now.addingTimeInterval(-7 * 86400))
        #expect(ProfileAutoUpdater.isDue(broken, at: now))
    }

    // MARK: - Harness

    private struct Harness {
        let updater: ProfileAutoUpdater
        let context: ModelContext
    }

    @MainActor
    private func makeProfile(
        url: String = "https://example.com/auto.yaml",
        interval: ProfileUpdateInterval,
        lastUpdated: Date,
        yaml: String = "proxies: []\n",
    ) -> Profile {
        Profile(
            name: "p",
            url: url,
            yamlContent: yaml,
            lastUpdated: lastUpdated,
            updateInterval: interval,
        )
    }

    /// In-memory store plus a temp-directory active-config file and a private
    /// `UserDefaults` suite — never the real App Group container.
    @MainActor
    private func makeUpdater(now: Date, session: URLSession) throws -> Harness {
        let container = try ModelContainer(
            for: Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true),
        )
        let context = ModelContext(container)
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ProfileAutoUpdaterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard let defaults = UserDefaults(suiteName: "ProfileAutoUpdaterTests-\(UUID().uuidString)") else {
            throw HarnessError.defaultsSuiteUnavailable
        }
        let service = SubscriptionService(
            modelContext: context,
            session: session,
            activeConfigDirectory: { dir },
            activeConfigURL: { dir.appending(path: "config.yaml") },
            preferences: defaults,
        )
        let updater = ProfileAutoUpdater(modelContext: context, service: service, now: { now })
        return Harness(updater: updater, context: context)
    }

    private func stubbedSession(_ responses: [String: URLProtocolStub.Response]) -> URLSession {
        for (url, response) in responses {
            URLProtocolStub.stub(URL(string: url)!, with: response)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

private enum HarnessError: Error {
    case defaultsSuiteUnavailable
}
