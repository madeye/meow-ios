import SwiftUI
import UIKit

struct YamlEditorView: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    @State private var text: String = ""
    @State private var error: String?
    @State private var errorLines: Set<Int> = []
    @State private var saving = false

    var body: some View {
        ClashYAMLTextView(text: $text, errorLines: errorLines)
            .overlay {
                if text.isEmpty {
                    ContentUnavailableView(
                        "yamlEditor.empty.title",
                        systemImage: "doc.text",
                        description: Text("yamlEditor.empty.description"),
                    )
                    .accessibilityIdentifier("yamlEditor.emptyState")
                }
            }
            .safeAreaInset(edge: .top) {
                if let error {
                    errorBanner(error)
                }
            }
            .navigationTitle("yamlEditor.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("yamlEditor.button.cancel") { dismiss() }
                        .accessibilityLabel("yamlEditor.a11y.cancel")
                        .accessibilityIdentifier("yamlEditor.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        LocalizedStringKey(saving ? "yamlEditor.button.saving" : "yamlEditor.button.save"),
                        action: save,
                    )
                    .disabled(saving || text.isEmpty)
                    .accessibilityLabel("yamlEditor.a11y.save")
                    .accessibilityValue(saving ? Text("yamlEditor.a11y.saving") : Text(""))
                    .accessibilityHint("yamlEditor.a11y.save.hint")
                    .accessibilityIdentifier("yamlEditor.saveButton")
                }
            }
            .onAppear { text = profile.yamlContent }
            .onChange(of: text) { _, _ in
                error = nil
                errorLines = []
            }
            .onChange(of: error) { _, newError in
                if newError != nil {
                    AccessibilityNotification.LayoutChanged().post()
                }
            }
    }

    private func save() {
        saving = true
        defer { saving = false }
        let lintIssues = ClashConfigLinter.lint(text)
        if let first = lintIssues.first {
            error = first.message
            errorLines = Set(lintIssues.map(\.line))
            return
        }
        do {
            try MeowConfigValidator.validate(text)
            profile.yamlBackup = profile.yamlContent
            profile.yamlContent = text
            try service.writeActiveConfig(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            errorLines = MeowConfigValidator.parseErrorLines(error.localizedDescription)
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
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("yamlEditor.a11y.errorBanner \(message)"))
        .accessibilityIdentifier("yamlEditor.errorBanner")
    }
}

enum MeowConfigValidator {
    static func validate(_ yaml: String) throws {
        let rc = yaml.withCString { ptr -> Int32 in
            meow_engine_validate_config(ptr, Int32(yaml.utf8.count))
        }
        if rc != 0 {
            let msg = meow_core_last_error().map { String(cString: $0) } ?? "invalid config"
            throw MeowConfigError.invalid(msg)
        }
    }

    static func parseErrorLines(_ message: String) -> Set<Int> {
        var lines: Set<Int> = []
        let rawPatterns = [
            #"at line (\d+)"#,
            #"line (\d+) column \d+"#,
            #"\[(\d+)\]"#,
        ]
        let nsMsg = message as NSString
        let range = NSRange(location: 0, length: nsMsg.length)
        for raw in rawPatterns {
            guard let regex = try? NSRegularExpression(pattern: raw) else { continue }
            for match in regex.matches(in: message, range: range)
                where match.numberOfRanges >= 2
            {
                if let n = Int(nsMsg.substring(with: match.range(at: 1))), n > 0 {
                    lines.insert(n)
                }
            }
        }
        return lines
    }
}

enum MeowConfigError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        let fallback = String(
            localized: "yamlEditor.error.invalid",
            comment: "Fallback message when config validation fails without engine detail",
        )
        if case let .invalid(msg) = self { return msg.isEmpty ? fallback : msg }
        return fallback
    }
}
