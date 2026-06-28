import Foundation
import MeowModels
import Observation
import os
import SwiftData

private let replayLog = Logger(subsystem: "com.tangzixiang.meow.app", category: "proxy-replay")

/// Top-level observable that wires the app's long-lived services together and
/// performs first-launch setup (asset seeding, IPC observer registration).
@MainActor
@Observable
final class AppModel {
    let vpnManager: VpnManager
    let meowAPI: MeowAPI
    let subscriptionService: SubscriptionService
    let ipcBridge: AppIPCBridge
    let dailyTrafficAccumulator: DailyTrafficAccumulator

    /// Monotonically bumped each time `replaySelectedProxies()` finishes a pass
    /// (successful replay, probe-timeout giveup, or no-active-profile no-op).
    /// EngineOverviewSection keys a `.task(id:)` on this so the proxy-groups UI
    /// re-fetches `/proxies` AFTER replay has had its chance to mutate engine state —
    /// otherwise the view-mount fetch on the `.connected` edge races the
    /// replay PUTs and caches pre-replay defaults.
    private(set) var replayGeneration: Int = 0

    private var didBootstrap = false

    init() {
        // Export XDG_CONFIG_HOME before any FFI callsite that might resolve
        // GEOIP rules (e.g. YamlEditorView's MeowConfigValidator →
        // meow_engine_validate_config). std::env::set_var is per-process, so
        // each of {App, PacketTunnel} needs its own call — PacketTunnel does
        // the same in TunnelEngine.start.
        AppGroup.containerURL.path.withCString { meow_core_set_home_dir($0) }

        vpnManager = VpnManager()
        // REST-API port + secret are minted by the engine (Rust
        // `meow_patch_config`) and shared via the App Group, so the loopback
        // control plane is authenticated on a non-well-known port. Until the
        // extension has patched a config once (no tunnel has ever started),
        // the file is absent; keep the client unconfigured until connect.
        let creds = AppGroup.apiCredentials()
        meowAPI = MeowAPI(port: creds?.port ?? 0, secret: creds?.secret ?? "")
        subscriptionService = SubscriptionService(
            modelContext: AppModelContainer.shared.container.mainContext,
        )
        ipcBridge = AppIPCBridge()
        dailyTrafficAccumulator = DailyTrafficAccumulator(
            modelContext: AppModelContainer.shared.container.mainContext,
        )
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        vpnManager.onConnected = { [weak self] in
            Task { @MainActor in
                await self?.replaySelectedProxies()
            }
        }
        try? FileManager.default.createDirectory(at: AppGroup.meowConfigDir, withIntermediateDirectories: true)
        AppGroup.configureBackup()
        GeoAssetStager.stageIfNeeded()
        await vpnManager.refresh()
        ipcBridge.start()
        dailyTrafficAccumulator.start()
    }

    /// Re-issues the active profile's persisted `selectedProxies` each time
    /// the tunnel transitions into `.connected`. meow-rs keeps group
    /// state in-memory only, so every engine.start resets it to the YAML
    /// defaults — without this the UI would show defaults instead of what
    /// the user last picked.
    ///
    /// Read-only against persistence: a saved selection that no longer
    /// exists server-side (group renamed, proxy removed) surfaces as an
    /// HTTP 4xx here; it is logged and ignored. We do NOT proactively
    /// delete the persisted entry — destructive cleanup on replay is how
    /// #59 silently erased the user's picks on a single unlucky reconnect.
    /// User can re-pick if they want; stale entries are otherwise harmless.
    private func replaySelectedProxies() async {
        defer { replayGeneration &+= 1 }
        let api = meowAPI
        // Retarget the client at the credentials the extension minted while
        // bringing the tunnel up. On a fresh install the credential file was
        // absent at `init`, so `api` is still unconfigured; the extension has
        // now written `api-credentials.json`, so pick it up before the probe
        // below or every request would hit the wrong port / fail auth.
        if let creds = AppGroup.apiCredentials() {
            api.updateCredentials(port: creds.port, secret: creds.secret)
        }
        // Cold-connect readiness probe. `meow_engine_start` returns before
        // the spawned api_server task binds the controller port, so a replay
        // fired on the `.connected` edge can race it. 1s cap (100ms × 10) is
        // plenty on device; we give up silently rather than retry forever.
        var ready = false
        for attempt in 0 ..< 10 {
            do {
                _ = try await api.getProxies()
                replayLog.notice("probe ready after \(attempt + 1) attempt(s)")
                ready = true
                break
            } catch {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard ready else {
            replayLog.error("probe gave up after 10 attempts — skipping replay")
            return
        }

        let context = AppModelContainer.shared.container.mainContext
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.isSelected })
        guard let profile = try? context.fetch(descriptor).first else {
            replayLog.notice("no active profile — nothing to replay")
            return
        }
        let selections = profile.selectedProxies
        replayLog.notice("replaying \(selections.count) selection(s)")
        for (group, proxy) in selections {
            do {
                try await api.selectProxy(group: group, name: proxy)
            } catch {
                replayLog.error(
                    """
                    selectProxy failed group=\(group, privacy: .public) \
                    proxy=\(proxy, privacy: .public) \
                    err=\(String(describing: error), privacy: .public)
                    """,
                )
            }
        }
    }
}
