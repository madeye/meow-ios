import Foundation
import os
import SwiftData

/// Refetches subscription profiles whose per-profile cadence
/// (`Profile.updateInterval`) has elapsed.
///
/// The app has no background-refresh entitlement — `UIBackgroundModes` is
/// spent on the tunnel extension — so "every day" / "every week" means "the
/// first foreground pass at or after the profile's due time", not a wake-up
/// while the app is dead. That's the cadence a subscription actually needs:
/// the app process is the only writer of `config.yaml`, so a refresh that
/// can't run until the app is open loses nothing.
///
/// Bookkeeping rides entirely on `Profile.lastUpdated`, which
/// `SubscriptionService.refresh(_:)` already stamps on success. So a manual
/// refresh (row swipe) also postpones the next automatic one, and there's no
/// second timestamp that can drift out of sync with the first.
@MainActor
final class ProfileAutoUpdater {
    /// Gap between due-checks while the app stays in the foreground. Coarse on
    /// purpose: the shortest cadence offered is daily, so minute precision
    /// buys nothing, and a tight loop would hammer a URL that's failing.
    static let tickInterval: Duration = .seconds(30 * 60)

    private let modelContext: ModelContext
    private let service: SubscriptionService
    private let now: () -> Date
    private let log = Logger(subsystem: "com.tangzixiang.meow.app", category: "profile-auto-update")

    private var tickTask: Task<Void, Never>?
    /// Guards against overlapping passes: a foreground transition landing on
    /// top of a running tick would otherwise refetch the same due profile
    /// twice concurrently.
    private var isRefreshing = false

    init(
        modelContext: ModelContext,
        service: SubscriptionService,
        now: @escaping () -> Date = Date.init,
    ) {
        self.modelContext = modelContext
        self.service = service
        self.now = now
    }

    /// Runs a due-check immediately, then every `tickInterval` until `stop()`.
    ///
    /// Idempotent: calling it while already started is a no-op, so a
    /// transient `.inactive` → `.active` scene bounce (notification centre,
    /// app switcher) neither stacks timers nor fires a redundant pass.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            // The first pass runs immediately — a launch or a return from
            // background is exactly when a daily/weekly window is most likely
            // to have elapsed unnoticed.
            await self?.refreshDueProfiles()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: ProfileAutoUpdater.tickInterval)
                } catch {
                    return // cancelled mid-sleep
                }
                await self?.refreshDueProfiles()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// One due-check pass: refetch every profile whose cadence has elapsed.
    ///
    /// A failure is logged and skipped rather than propagated — one dead
    /// subscription URL must not stop the others from updating. Since
    /// `lastUpdated` only advances on a successful fetch, a profile that
    /// failed here stays due and is retried on the next pass.
    func refreshDueProfiles() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let all: [Profile]
        do {
            all = try modelContext.fetch(FetchDescriptor<Profile>())
        } catch {
            log.error("profile fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let due = ProfileAutoUpdater.dueProfiles(in: all, at: now())
        guard !due.isEmpty else { return }
        log.notice("\(due.count, privacy: .public) profile(s) due for auto-update")
        for profile in due {
            do {
                try await service.refresh(profile)
            } catch {
                log.error(
                    """
                    auto-update failed id=\(profile.id.uuidString, privacy: .public) \
                    err=\(String(describing: error), privacy: .public)
                    """,
                )
            }
        }
    }

    /// Profiles whose automatic-refresh window has elapsed as of `date`.
    static func dueProfiles(in profiles: [Profile], at date: Date) -> [Profile] {
        profiles.filter { isDue($0, at: date) }
    }

    /// The cadence policy, kept pure and static so it's testable without a
    /// network stub or a live timer.
    static func isDue(_ profile: Profile, at date: Date) -> Bool {
        // Local YAML imports have no remote to refetch.
        guard !profile.url.isEmpty else { return false }
        guard let window = profile.updateInterval.refreshAfter else { return false }
        let age = date.timeIntervalSince(profile.lastUpdated)
        // A stamp in the future can only come from a device clock that has
        // since been corrected backwards. Treat it as due: the refresh
        // restamps `lastUpdated` to now, which unsticks the cadence rather
        // than freezing this profile until real time catches up.
        guard age >= 0 else { return true }
        return age >= window
    }
}
