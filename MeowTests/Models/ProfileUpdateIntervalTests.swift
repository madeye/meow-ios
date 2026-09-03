import Foundation
@testable import meow_ios
import Testing

/// The auto-update cadence enum and its `Profile` accessor. The cadence is
/// persisted as a raw string rather than an enum, so the decode path (including
/// values this build doesn't know) is part of the contract.
@Suite("ProfileUpdateInterval", .tags(.model))
struct ProfileUpdateIntervalTests {
    @Test
    func `manual never comes due, daily and weekly carry their windows`() {
        #expect(ProfileUpdateInterval.manual.refreshAfter == nil)
        #expect(ProfileUpdateInterval.daily.refreshAfter == 86400)
        #expect(ProfileUpdateInterval.weekly.refreshAfter == 604_800)
    }

    @Test
    func `all three options are offered to the picker, manual first`() {
        #expect(ProfileUpdateInterval.allCases == [.manual, .daily, .weekly])
    }

    @Test
    func `each case has a distinct title key`() {
        let keys = Set(ProfileUpdateInterval.allCases.map(\.titleKey))
        #expect(keys.count == ProfileUpdateInterval.allCases.count)
    }

    @Test
    func `known raw values decode, unknown ones degrade to manual`() {
        #expect(ProfileUpdateInterval(storedRawValue: "daily") == .daily)
        #expect(ProfileUpdateInterval(storedRawValue: "weekly") == .weekly)
        // Written by a newer build, then read back by this one.
        #expect(ProfileUpdateInterval(storedRawValue: "hourly") == .manual)
        #expect(ProfileUpdateInterval(storedRawValue: "") == .manual)
    }

    @Test
    func `a profile defaults to manual so pre-feature profiles stay quiet`() {
        let profile = Profile(name: "p", url: "https://example.com/a.yaml", yamlContent: "")
        #expect(profile.updateInterval == .manual)
        #expect(profile.updateIntervalRaw == "manual")
    }

    @Test
    func `the interval accessor round-trips through the stored raw value`() {
        let profile = Profile(
            name: "p",
            url: "https://example.com/a.yaml",
            yamlContent: "",
            updateInterval: .weekly,
        )
        #expect(profile.updateIntervalRaw == "weekly")

        profile.updateInterval = .daily
        #expect(profile.updateIntervalRaw == "daily")
        #expect(profile.updateInterval == .daily)
    }

    @Test
    func `an unknown stored raw value reads back as manual`() {
        let profile = Profile(name: "p", url: "https://example.com/a.yaml", yamlContent: "")
        profile.updateIntervalRaw = "fortnightly"
        #expect(profile.updateInterval == .manual)
    }
}
