import SwiftUI

/// Modal editor for a single rule. Used both for "add new rule" (initial
/// EditableRule has empty payload + sensible defaults) and "edit existing
/// rule" (initial value preloaded). The caller owns persistence — this
/// sheet only mutates a local copy and hands it back via `onSave` when the
/// user confirms.
struct RuleEditorSheet: View {
    /// Proxy / group names available in the active config. Drives the
    /// proxy picker — typing freeform is also allowed (the engine's parser
    /// is the source of truth, and rule-providers can reference names
    /// that don't appear in the live proxy list).
    let availableProxies: [String]

    /// Initial rule state. The sheet edits a local copy so cancellation
    /// discards changes cleanly.
    let initial: EditableRule

    /// Called when the user taps Save. The caller closes the sheet.
    let onSave: (EditableRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var type: EditableRuleType
    @State private var payload: String
    @State private var proxy: String
    @State private var noResolve: Bool
    /// Flags other than `no-resolve` are preserved verbatim (meow gains
    /// flags faster than we model them; round-tripping the rest avoids
    /// silently dropping a `src` flag we don't know about yet).
    @State private var otherFlags: [String]

    init(
        availableProxies: [String],
        initial: EditableRule,
        onSave: @escaping (EditableRule) -> Void,
    ) {
        self.availableProxies = availableProxies
        self.initial = initial
        self.onSave = onSave
        let mappedType = EditableRuleType(rawValue: initial.type) ?? .domainSuffix
        _type = State(initialValue: mappedType)
        _payload = State(initialValue: initial.payload)
        _proxy = State(initialValue: initial.proxy)
        _noResolve = State(initialValue: initial.flags.contains("no-resolve"))
        _otherFlags = State(initialValue: initial.flags.filter { $0 != "no-resolve" })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("ruleEditor.section.type") {
                    Picker("ruleEditor.field.type", selection: $type) {
                        ForEach(EditableRuleType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .accessibilityIdentifier("ruleEditor.typePicker")
                }

                if type.takesPayload {
                    Section("ruleEditor.section.payload") {
                        TextField("ruleEditor.field.payload", text: $payload)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ruleEditor.payloadField")
                    }
                }

                Section("ruleEditor.section.proxy") {
                    if availableProxies.isEmpty {
                        TextField("ruleEditor.field.proxy", text: $proxy)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ruleEditor.proxyField")
                    } else {
                        // Picker over known names + a "Custom…" escape so
                        // users can still target rule-provider-only names
                        // that don't show up in /proxies. The Custom row
                        // surfaces the freeform TextField beneath.
                        Picker("ruleEditor.field.proxy", selection: $proxy) {
                            ForEach(availableProxies, id: \.self) { p in
                                Text(p).tag(p)
                            }
                            if !availableProxies.contains(proxy), !proxy.isEmpty {
                                Text(proxy).tag(proxy)
                            }
                        }
                        .accessibilityIdentifier("ruleEditor.proxyPicker")

                        TextField("ruleEditor.field.proxy.custom", text: $proxy)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ruleEditor.proxyField")
                    }
                }

                if type.supportsNoResolve {
                    Section {
                        Toggle("ruleEditor.field.noResolve", isOn: $noResolve)
                            .accessibilityIdentifier("ruleEditor.noResolveToggle")
                    } footer: {
                        Text("ruleEditor.field.noResolve.footer")
                    }
                }
            }
            .navigationTitle("ruleEditor.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ruleEditor.button.cancel") { dismiss() }
                        .accessibilityIdentifier("ruleEditor.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ruleEditor.button.save", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("ruleEditor.saveButton")
                }
            }
        }
    }

    private var canSave: Bool {
        if proxy.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if type.takesPayload, payload.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func save() {
        var flags = otherFlags
        if type.supportsNoResolve, noResolve {
            flags.append("no-resolve")
        }
        let rule = EditableRule(
            id: initial.id,
            type: type.rawValue,
            payload: type.takesPayload ? payload.trimmingCharacters(in: .whitespaces) : "",
            proxy: proxy.trimmingCharacters(in: .whitespaces),
            flags: flags,
        )
        onSave(rule)
        dismiss()
    }
}
