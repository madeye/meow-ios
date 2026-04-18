import MeowIPC
import MeowModels
import NetworkExtension
import SwiftUI

/// T4.10 — User-Facing Diagnostics Screen. Pushed from Settings. Three test
/// cards (Direct TCP, Proxy HTTP, DNS Resolver) with user-supplied inputs
/// and per-card latency-or-error results.
///
/// Process-affinity split (see `docs/PROJECT_PLAN.md §T4.10 addendum` and
/// `feedback_verify_ffi_process_affinity.md`):
///
/// - `meow_engine_test_direct_tcp` does not gate on `engine::tunnel()` in
///   the Rust FFI, so the Direct TCP card calls it in-process from the app
///   and stays enabled even when the tunnel is down.
/// - `meow_engine_test_proxy_http` and `meow_engine_test_dns` both require
///   `engine::tunnel()` which is `Some` only inside the PacketTunnel
///   extension process. Those two cards route via `DiagnosticsIPC`'s
///   user-request tag (`0x02`) → `PacketTunnelProvider.handleAppMessage`
///   → `DiagnosticsRunner.runUser(request:)`.
///
/// When the tunnel is not `.connected`, the whole Proxy+DNS section is
/// replaced with a single `ContentUnavailableView("VPN required")` rather
/// than per-card disabled states — two unusable cards side-by-side is a
/// worse signal than one clear "needs VPN" message.
struct UserDiagnosticsView: View {
    @Environment(VpnManager.self) private var vpnManager
    @State private var error: String?

    var body: some View {
        Form {
            directTcpSection
            if vpnManager.stage == .connected {
                proxyHttpSection
                dnsSection
            } else {
                vpnRequiredSection
            }
        }
        .safeAreaInset(edge: .top) {
            if let error {
                errorBanner(error)
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var directTcpSection: some View {
        Section("Direct TCP") {
            DirectTcpCard(errorSink: $error)
        }
    }

    private var proxyHttpSection: some View {
        Section("Proxy HTTP") {
            ProxyHttpCard(errorSink: $error)
        }
    }

    private var dnsSection: some View {
        Section("DNS Resolver") {
            DnsCard(errorSink: $error)
        }
    }

    private var vpnRequiredSection: some View {
        Section {
            ContentUnavailableView(
                "VPN required",
                systemImage: "network.slash",
                description: Text("Connect to the proxy to run Proxy HTTP and DNS Resolver checks."),
            )
            .accessibilityIdentifier("userDiagnostics.emptyState")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityIdentifier("userDiagnostics.errorBanner")
    }
}

// MARK: - Cards

private struct DirectTcpCard: View {
    @Binding var errorSink: String?
    @State private var input: String = ""
    @State private var result: UserDiagnosticsCardResult?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("1.1.1.1:443", text: $input)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("userDiagnostics.directTcp.input")
            HStack {
                Button(running ? "Testing…" : "Test", action: runTest)
                    .disabled(running || input.isEmpty)
                    .accessibilityIdentifier("userDiagnostics.directTcp.button")
                Spacer()
                if let result {
                    resultLabel(result)
                        .accessibilityIdentifier("userDiagnostics.directTcp.result")
                }
            }
        }
    }

    private func runTest() {
        let snapshot = input.trimmingCharacters(in: .whitespaces)
        guard !snapshot.isEmpty else { return }
        let parsed = parseHostPort(snapshot)
        guard let (host, port) = parsed else {
            errorSink = "Expected host:port (e.g. 1.1.1.1:443)"
            return
        }
        errorSink = nil
        running = true
        result = nil
        Task {
            let response = await Task.detached(priority: .userInitiated) {
                UserDiagnosticsExec.directTcp(host: host, port: port, timeoutMs: 5000)
            }.value
            result = UserDiagnosticsCardResult(response: response)
            running = false
        }
    }

    private func parseHostPort(_ text: String) -> (String, Int32)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon])
        let portText = String(text[text.index(after: colon)...])
        guard !host.isEmpty, let port = Int32(portText), port > 0, port <= 65535 else { return nil }
        return (host, port)
    }
}

private struct ProxyHttpCard: View {
    @Binding var errorSink: String?
    @State private var input: String = ""
    @State private var result: UserDiagnosticsCardResult?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("https://www.gstatic.com/generate_204", text: $input)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("userDiagnostics.proxyHttp.input")
            HStack {
                Button(running ? "Testing…" : "Test", action: runTest)
                    .disabled(running || input.isEmpty)
                    .accessibilityIdentifier("userDiagnostics.proxyHttp.button")
                Spacer()
                if let result {
                    resultLabel(result)
                        .accessibilityIdentifier("userDiagnostics.proxyHttp.result")
                }
            }
        }
    }

    private func runTest() {
        let snapshot = input.trimmingCharacters(in: .whitespaces)
        guard !snapshot.isEmpty else { return }
        errorSink = nil
        running = true
        result = nil
        Task {
            let response = await UserDiagnosticsClient.send(.proxyHttp(url: snapshot, timeoutMs: 5000))
            result = UserDiagnosticsCardResult(response: response)
            running = false
        }
    }
}

private struct DnsCard: View {
    @Binding var errorSink: String?
    @State private var input: String = ""
    @State private var result: UserDiagnosticsCardResult?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("example.com", text: $input)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("userDiagnostics.dns.input")
            HStack {
                Button(running ? "Testing…" : "Test", action: runTest)
                    .disabled(running || input.isEmpty)
                    .accessibilityIdentifier("userDiagnostics.dns.button")
                Spacer()
                if let result {
                    resultLabel(result)
                        .accessibilityIdentifier("userDiagnostics.dns.result")
                }
            }
        }
    }

    private func runTest() {
        let snapshot = input.trimmingCharacters(in: .whitespaces)
        guard !snapshot.isEmpty else { return }
        errorSink = nil
        running = true
        result = nil
        Task {
            let response = await UserDiagnosticsClient.send(.dns(host: snapshot, timeoutMs: 3000))
            result = UserDiagnosticsCardResult(response: response)
            running = false
        }
    }
}

// MARK: - Result rendering

private enum UserDiagnosticsCardResult {
    case success(latencyMs: Int64, httpStatus: Int32?)
    case failure(reason: String)

    init(response: UserDiagnosticsResponse) {
        if response.success, let latency = response.latencyMs {
            self = .success(latencyMs: latency, httpStatus: response.httpStatus)
        } else {
            self = .failure(reason: response.errorReason ?? "unknown_error")
        }
    }
}

@ViewBuilder
private func resultLabel(_ result: UserDiagnosticsCardResult) -> some View {
    switch result {
    case let .success(latencyMs, httpStatus):
        if let httpStatus {
            Text("\(httpStatus) · \(latencyMs) ms")
                .font(.caption.monospaced())
                .foregroundStyle(httpStatus >= 200 && httpStatus < 400 ? .green : .orange)
        } else {
            Text("\(latencyMs) ms")
                .font(.caption.monospaced())
                .foregroundStyle(.green)
        }
    case let .failure(reason):
        Text(reason)
            .font(.caption.monospaced())
            .foregroundStyle(.red)
            .lineLimit(2)
    }
}

// MARK: - In-app Direct TCP executor

/// Non-main-actor helper for the Direct TCP FFI, called from a detached
/// Task so the blocking C call doesn't stall the SwiftUI main actor.
enum UserDiagnosticsExec {
    static func directTcp(host: String, port: Int32, timeoutMs: Int32) -> UserDiagnosticsResponse {
        var ms: Int64 = 0
        let rc = host.withCString { ptr in
            meow_engine_test_direct_tcp(ptr, port, timeoutMs, &ms)
        }
        if rc < 0 {
            return .failure(reason: lastRustErrorReason(fallback: "connect_failed"))
        }
        return .success(latencyMs: ms)
    }

    private static func lastRustErrorReason(fallback: String) -> String {
        guard let cstr = meow_core_last_error() else { return fallback }
        let msg = String(cString: cstr)
        return msg.isEmpty ? fallback : msg
    }
}

// MARK: - IPC client

/// App-side client for the T4.10 user-diagnostics IPC. Sends a
/// `UserDiagnosticsRequest` to the PacketTunnel extension via
/// `NETunnelProviderSession.sendProviderMessage`. If the extension is not
/// reachable (no session, not running, send throws), returns a synthetic
/// `tunnel_not_running` failure — same convention the T2.6
/// `DiagnosticsClient` uses.
enum UserDiagnosticsClient {
    static func send(_ request: UserDiagnosticsRequest) async -> UserDiagnosticsResponse {
        let unreachable = UserDiagnosticsResponse.failure(reason: "tunnel_not_running")
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            return unreachable
        }
        guard let session = managers.first?.connection as? NETunnelProviderSession else {
            return unreachable
        }
        let payload: Data
        do {
            payload = try DiagnosticsIPC.encodeUserRequest(request)
        } catch {
            return .failure(reason: "encode_failed")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<UserDiagnosticsResponse, Never>) in
            do {
                try session.sendProviderMessage(payload) { data in
                    guard let data, let response = try? DiagnosticsIPC.decodeUserResponse(data) else {
                        cont.resume(returning: unreachable)
                        return
                    }
                    cont.resume(returning: response)
                }
            } catch {
                cont.resume(returning: unreachable)
            }
        }
    }
}
