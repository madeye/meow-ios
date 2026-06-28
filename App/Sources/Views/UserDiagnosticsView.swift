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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        .navigationTitle("userDiagnostics.nav.title")
    }

    private var directTcpSection: some View {
        Section("userDiagnostics.section.directTcp") {
            DirectTcpCard(errorSink: $error)
        }
    }

    private var proxyHttpSection: some View {
        Section("userDiagnostics.section.proxyHttp") {
            ProxyHttpCard(errorSink: $error)
        }
    }

    private var dnsSection: some View {
        Section("userDiagnostics.section.dns") {
            DnsCard(errorSink: $error)
        }
    }

    private var vpnRequiredSection: some View {
        Section {
            ContentUnavailableView(
                "userDiagnostics.empty.title",
                systemImage: "network.slash",
                description: Text("userDiagnostics.empty.description"),
            )
            .accessibilityIdentifier("userDiagnostics.emptyState")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.secondarySystemBackground))
                : AnyShapeStyle(.regularMaterial),
            in: .rect(cornerRadius: 8),
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.userDiagnostics.errorBanner \(message)"))
        .accessibilityIdentifier("userDiagnostics.errorBanner")
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
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
                .accessibilityLabel("a11y.userDiagnostics.directTcp.input")
                .accessibilityIdentifier("userDiagnostics.directTcp.input")
            HStack {
                Button(action: runTest) {
                    Text(LocalizedStringKey(running ? "userDiagnostics.button.testing" : "userDiagnostics.button.test"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(running || input.isEmpty)
                .accessibilityLabel(
                    running
                        ? Text("userDiagnostics.button.testing")
                        : Text("a11y.userDiagnostics.directTcp.test"),
                )
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
            errorSink = String(
                localized: "userDiagnostics.error.parseHostPort",
                comment: "Shown when user-entered Direct TCP target doesn't parse as host:port",
            )
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
                .accessibilityLabel("a11y.userDiagnostics.proxyHttp.input")
                .accessibilityIdentifier("userDiagnostics.proxyHttp.input")
            HStack {
                Button(action: runTest) {
                    Text(LocalizedStringKey(running ? "userDiagnostics.button.testing" : "userDiagnostics.button.test"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(running || input.isEmpty)
                .accessibilityLabel(
                    running
                        ? Text("userDiagnostics.button.testing")
                        : Text("a11y.userDiagnostics.proxyHttp.test"),
                )
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
                .accessibilityLabel("a11y.userDiagnostics.dns.input")
                .accessibilityIdentifier("userDiagnostics.dns.input")
            HStack {
                Button(action: runTest) {
                    Text(LocalizedStringKey(running ? "userDiagnostics.button.testing" : "userDiagnostics.button.test"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(running || input.isEmpty)
                .accessibilityLabel(
                    running
                        ? Text("userDiagnostics.button.testing")
                        : Text("a11y.userDiagnostics.dns.test"),
                )
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
                .foregroundStyle(httpStatus >= 200 && httpStatus < 400 ? AppTheme.connected : AppTheme.warning)
                .accessibilityLabel(
                    Text("a11y.userDiagnostics.result.httpStatus \(String(httpStatus)) \(String(latencyMs))"),
                )
        } else {
            Text("\(latencyMs) ms")
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.connected)
                .accessibilityLabel(Text("a11y.userDiagnostics.result.success \(String(latencyMs))"))
        }
    case let .failure(reason):
        Text(reason)
            .font(.caption.monospaced())
            .foregroundStyle(AppTheme.danger)
            .lineLimit(2)
            .accessibilityLabel(Text("a11y.userDiagnostics.result.failure \(reason)"))
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
