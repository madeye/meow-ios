import Foundation
import NetworkExtension
import os.log
import MeowIPC
import MeowModels

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "io.github.madeye.meow.PacketTunnel", category: "provider")
    private var engine: TunnelEngine?
    private var ipcListener: IPCListener?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("startTunnel")

        let settings = TunnelSettings.make(serverAddress: protocolConfiguration.serverAddress ?? "meow")
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            Task {
                do {
                    let engine = TunnelEngine(packetFlow: self.packetFlow)
                    try await engine.start()
                    self.engine = engine

                    let listener = IPCListener { [weak self] intent in
                        Task { await self?.handle(intent: intent) }
                    }
                    listener.start()
                    self.ipcListener = listener

                    self.writeState(.connected, profileID: options?["profileID"] as? String)
                    completionHandler(nil)
                } catch {
                    self.log.error("engine start failed: \(error.localizedDescription)")
                    self.writeState(.error, errorMessage: error.localizedDescription)
                    completionHandler(error)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopTunnel reason=\(String(describing: reason))")
        Task {
            await engine?.stop()
            engine = nil
            ipcListener?.stop()
            ipcListener = nil
            writeState(.stopped)
            completionHandler()
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
