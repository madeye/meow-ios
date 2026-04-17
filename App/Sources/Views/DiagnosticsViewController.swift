import MeowIPC
import MeowModels
import NetworkExtension
import SwiftUI
import UIKit

/// UIKit debug panel per PRD §4.4 Diagnostics Surface Contract. Rendered as
/// a plain `UIViewController` with `UILabel` rows in a vertical stack — not
/// SwiftUI — so the vphone-cli nightly OCR harness sees pixel-stable
/// positions. `accessibilityIdentifier` on each row gives XCUITest a stable
/// anchor. Text format: `CHECK_NAME: PASS` or `CHECK_NAME: FAIL(reason)`,
/// uppercase, ASCII, no emoji; `DiagnosticsLabelParser.render(_:)` is the
/// single source of truth for formatting.
final class DiagnosticsViewController: UIViewController {
    static let runButtonAccessibilityID = "diagnostics.button.run"
    static let rowAccessibilityIDPrefix = "diagnostics.row."

    private var rowLabels: [DiagnosticsCheck: UILabel] = [:]
    private var currentResults: [DiagnosticsCheck: DiagnosticsResult] = {
        var d: [DiagnosticsCheck: DiagnosticsResult] = [:]
        for c in DiagnosticsCheck.allCases {
            d[c] = .fail(reason: "not_run")
        }
        return d
    }()

    private var runButton: UIButton!
    private var isRunning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Diagnostics"
        view.backgroundColor = .systemBackground
        buildLayout()
        refreshLabels()
    }

    private func buildLayout() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for check in DiagnosticsCheck.allCases {
            let label = UILabel()
            label.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)
            label.textColor = .label
            label.backgroundColor = .clear
            label.accessibilityIdentifier = Self.rowAccessibilityIDPrefix + check.rawValue
            label.numberOfLines = 1
            rowLabels[check] = label
            stack.addArrangedSubview(label)
        }

        var runConfig = UIButton.Configuration.borderedProminent()
        runConfig.title = "Run"
        runButton = UIButton(configuration: runConfig, primaryAction: UIAction { [weak self] _ in
            self?.runDiagnostics()
        })
        runButton.accessibilityIdentifier = Self.runButtonAccessibilityID
        runButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(runButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20),

            runButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
            runButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
        ])
    }

    private func runDiagnostics() {
        guard !isRunning else { return }
        isRunning = true
        runButton.isEnabled = false
        for check in DiagnosticsCheck.allCases {
            currentResults[check] = .fail(reason: "running")
        }
        refreshLabels()

        Task { [weak self] in
            let report = await DiagnosticsClient.requestReport()
            await MainActor.run {
                guard let self else { return }
                self.currentResults = report.asDictionary()
                self.refreshLabels()
                self.isRunning = false
                self.runButton.isEnabled = true
            }
        }
    }

    private func refreshLabels() {
        for check in DiagnosticsCheck.allCases {
            rowLabels[check]?.text = formattedRow(for: check)
        }
    }

    private func formattedRow(for check: DiagnosticsCheck) -> String {
        switch currentResults[check] ?? .fail(reason: "missing") {
        case .pass: "\(check.rawValue): PASS"
        case let .fail(reason): "\(check.rawValue): FAIL(\(reason))"
        }
    }
}

/// App-side client for the diagnostics IPC. Uses `NETunnelProviderSession`'s
/// `sendProviderMessage` for request/response (not the shared UserDefaults
/// mailbox — that's fire-and-forget). If the extension isn't running, every
/// check reports `FAIL(tunnel_not_running)`.
enum DiagnosticsClient {
    static func requestReport() async -> DiagnosticsReport {
        let failAll = DiagnosticsReport(
            tunExists: .fail("tunnel_not_running"),
            dnsOk: .fail("tunnel_not_running"),
            tcpProxyOk: .fail("tunnel_not_running"),
            http204Ok: .fail("tunnel_not_running"),
            memOk: .fail("tunnel_not_running"),
        )

        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            return failAll
        }
        guard let session = managers.first?.connection as? NETunnelProviderSession else {
            return failAll
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<DiagnosticsReport, Never>) in
            do {
                try session.sendProviderMessage(DiagnosticsIPC.encodeRequest()) { data in
                    guard let data, let report = try? DiagnosticsIPC.decodeResponse(data) else {
                        cont.resume(returning: failAll)
                        return
                    }
                    cont.resume(returning: report)
                }
            } catch {
                cont.resume(returning: failAll)
            }
        }
    }
}

/// SwiftUI bridge so the existing Settings Debug section can push to this
/// view controller without the call-site needing to know about UIKit.
struct DiagnosticsPanelView: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> DiagnosticsViewController {
        DiagnosticsViewController()
    }

    func updateUIViewController(_: DiagnosticsViewController, context _: Context) {}
}
