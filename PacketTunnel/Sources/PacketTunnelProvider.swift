import Foundation
import NetworkExtension
import os.log
import MeowIPC
import MeowModels

// @unchecked Sendable: the NetworkExtension runtime serializes provider
// lifecycle callbacks (startTunnel/stopTunnel/sleep/wake) onto a single
// internal queue, so cross-actor hops inside this class are safe.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let log = Logger(subsystem: "io.github.madeye.meow.PacketTunnel", category: "provider")
    private var engine: TunnelEngine?
    private var ipcListener: IPCListener?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        log.info("startTunnel")

        let settings = TunnelSettings.make(serverAddress: protocolConfiguration.serverAddress ?? "meow")
        let profileID = options?["profileID"] as? String
        Task { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            do {
                try await self.applySettings(settings)
                let engine = TunnelEngine(packetFlow: self.packetFlow)
                try await engine.start()
                self.engine = engine

                let listener = IPCListener { [weak self] intent in
                    Task { await self?.handle(intent: intent) }
                }
                listener.start()
                self.ipcListener = listener

                self.writeState(.connected, profileID: profileID)
                completionHandler(nil)
            } catch {
                self.log.error("engine start failed: \(error.localizedDescription)")
                self.writeState(.error, errorMessage: error.localizedDescription)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        log.info("stopTunnel reason=\(String(describing: reason))")
        Task { [weak self] in
            await self?.engine?.stop()
            self?.engine = nil
            self?.ipcListener?.stop()
            self?.ipcListener = nil
            self?.writeState(.stopped)
            completionHandler()
        }
    }

    private func applySettings(_ settings: NEPacketTunnelNetworkSettings) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    // MARK: - Private

    private func handle(intent: TunnelIntent) async {
        switch intent.command {
        case .start:
            // Engine is already running — nothing to do. A future enhancement
            // will swap the active profile without tearing down the tunnel.
            break
        case .stop:
            cancelTunnelWithError(nil)
        case .reload:
            do {
                try await engine?.reloadConfig()
            } catch {
                log.error("reload failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeState(
        _ stage: VpnStage,
        profileID: String? = nil,
        errorMessage: String? = nil
    ) {
        var state = SharedStore.readState() ?? VpnState()
        state.stage = stage
        if let profileID { state.profileID = profileID }
        state.errorMessage = errorMessage
        state.startedAt = (stage == .connected) ? Date() : state.startedAt
        do {
            try SharedStore.writeState(state)
            DarwinBridge.post(.state)
        } catch {
            log.error("failed to write state: \(error.localizedDescription)")
        }
    }
}
