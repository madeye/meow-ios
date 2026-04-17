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
        CodeTextView(text: $text)
            .navigationTitle("Edit Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert") { text = profile.yamlBackup }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save", action: save)
                        .disabled(saving)
                }
            }
            .onAppear { text = profile.yamlContent }
            .alert("Save failed", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
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
        if case .invalid(let msg) = self { return msg.isEmpty ? "Invalid config" : msg }
        return "Invalid config"
    }
}

/// Wraps UITextView for a no-dependency monospace editor. Syntax highlighting
/// will replace this with CodeEditView once the YAML editor milestone lands.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
