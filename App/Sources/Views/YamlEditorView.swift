import SwiftUI
import UIKit

struct YamlEditorView: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    @State private var text: String = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        CodeTextView(text: $text, accessibilityIdentifier: "yamlEditor.editor")
            .overlay {
                if text.isEmpty {
                    ContentUnavailableView(
                        "Empty config",
                        systemImage: "doc.text",
                        description: Text("Paste a Clash YAML config to start editing."),
                    )
                    .accessibilityIdentifier("yamlEditor.emptyState")
                }
            }
            .safeAreaInset(edge: .top) {
                if let error {
                    errorBanner(error)
                }
            }
            .navigationTitle("Edit Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert") { text = profile.yamlBackup }
                        .accessibilityLabel("Revert to last saved config")
                        .accessibilityIdentifier("yamlEditor.revertButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save", action: save)
                        .disabled(saving || text.isEmpty)
                        .accessibilityLabel("Save config")
                        .accessibilityIdentifier("yamlEditor.saveButton")
                }
            }
            .onAppear { text = profile.yamlContent }
            .onChange(of: text) { _, _ in
                if error != nil { error = nil }
            }
    }

    private func save() {
        saving = true
        defer { saving = false }
        do {
            try MihomoConfigValidator.validate(text)
            profile.yamlBackup = profile.yamlContent
            profile.yamlContent = text
            try service.writeActiveConfig(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
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
        .accessibilityIdentifier("yamlEditor.errorBanner")
    }
}

enum MihomoConfigValidator {
    /// Validates a YAML config via the Rust FFI (`meow_engine_validate_config`)
    /// which runs the same `load_config_from_str` path the engine uses at
    /// start time.
    static func validate(_ yaml: String) throws {
        let rc = yaml.withCString { ptr -> Int32 in
            meow_engine_validate_config(ptr, Int32(yaml.utf8.count))
        }
        if rc != 0 {
            let msg = meow_core_last_error().map { String(cString: $0) } ?? "invalid config"
            throw MihomoConfigError.invalid(msg)
        }
    }
}

enum MihomoConfigError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(msg) = self { return msg.isEmpty ? "Invalid config" : msg }
        return "Invalid config"
    }
}

/// Wraps UITextView for a no-dependency monospace editor. Syntax highlighting
/// will replace this with CodeEditView once the YAML editor milestone lands.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let accessibilityIdentifier: String?

    init(text: Binding<String>, accessibilityIdentifier: String? = nil) {
        _text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.accessibilityIdentifier = accessibilityIdentifier
        return view
    }

    func updateUIView(_ uiView: UITextView, context _: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
