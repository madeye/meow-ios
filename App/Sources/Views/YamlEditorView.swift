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
            try service.updateContent(profile, yaml: text)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            errorLines = MeowConfigValidator.parseErrorLines(error.localizedDescription)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        ErrorBanner(
            message: message,
            accessibilityLabel: Text("yamlEditor.a11y.errorBanner \(message)"),
            identifier: "yamlEditor.errorBanner",
        )
    }
}
