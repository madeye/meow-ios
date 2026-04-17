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
    static func validate(_ yaml: String) throws {
        #if MIHOMO_GO_LINKED
        let data = Array(yaml.utf8)
        let result = data.withUnsafeBufferPointer { buf -> Int32 in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { base in
                meowValidateConfig(base, Int32(buf.count))
            }
        }
        if result != 0 { throw MihomoConfigError.invalid(MihomoErrorReader.read()) }
        #else
        // Offline fallback: at least ensure the bytes are valid YAML. The real
        // validator is the mihomo executor, which we'll wire up once the Go
        // XCFramework is linked.
        _ = try Yams.load(yaml: yaml)
        #endif
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
