import Foundation
import MeowIPC
import MeowModels
import NetworkExtension
import os.log

/// @unchecked Sendable: the NetworkExtension runtime serializes provider
/// lifecycle callbacks (startTunnel/stopTunnel/sleep/wake) onto a single
/// internal queue, so cross-actor hops inside this class are safe.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let log = Logger(subsystem: "io.github.madeye.meow.PacketTunnel", category: "provider")
    private var engine: TunnelEngine?
    private var ipcListener: IPCListener?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping @Sendable (Error?) -> Void,
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
                try await applySettings(settings)
                let engine = TunnelEngine(packetFlow: packetFlow)
                try await engine.start()
                self.engine = engine

                let listener = IPCListener { [weak self] intent in
                    Task { await self?.handle(intent: intent) }
                }
                listener.start()
                ipcListener = listener

                writeState(.connected, profileID: profileID)
                completionHandler(nil)
            } catch {
                log.error("engine start failed: \(error.localizedDescription)")
                writeState(.error, errorMessage: error.localizedDescription)
                completionHandler(error)
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard DiagnosticsIPC.isRequest(messageData) else {
            completionHandler?(nil)
            return
        }
        // Diagnostics checks call into blocking Rust FFI (DNS, TCP connect,
        // HTTP fetch). Run off the provider queue on a GCD-managed worker so
        // we don't stall `handleAppMessage`'s caller. The NE completion
        // handler is not @Sendable, so we can't hop through a Task; GCD is
        // the correct tool here.
        let engine = engine
        let handler = UnsafeSendableBox(completionHandler)
        DispatchQueue.global(qos: .userInitiated).async {
            let report = engine?.runDiagnostics() ?? DiagnosticsReport(
                tunExists: .fail("engine_not_running"),
                dnsOk: .fail("engine_not_running"),
                tcpProxyOk: .fail("engine_not_running"),
                http204Ok: .fail("engine_not_running"),
                memOk: .fail("engine_not_running"),
            )
            let data = (try? DiagnosticsIPC.encodeResponse(report)) ?? Data()
            handler.value?(data)
        }
    }

    /// `NEPacketTunnelProvider.handleAppMessage` hands us a non-Sendable
    /// completion callback; this wrapper lets us pass it across a GCD
    /// dispatch in Swift 6 strict mode. The runtime guarantees the callback
    /// itself is only invoked from one thread.
    private struct UnsafeSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) {
            self.value = value
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
        errorMessage: String? = nil,
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
