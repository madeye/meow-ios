import Accessibility
import MeowModels
import SwiftUI

/// Structured rules editor. Presented as a sheet from `RulesView`.
///
/// Reads the `rules:` block out of the active `Profile.yamlContent` (the
/// source of truth before the extension patches it for engine startup),
/// exposes Add / Delete / Reorder / per-row editing, validates the rewritten YAML through the FFI's
/// `MeowConfigValidator`, persists back to the Profile, and writes the
/// active config so the engine picks it up on next start.
///
/// Changes do not hot-apply: meow-rs has no rule-set-only reload path
/// today (and the rule index is built once at engine start in
/// `Tunnel::update_rules`). The view surfaces a banner reminding the user
/// to reconnect the tunnel when the editor closes with unsaved-to-engine
/// changes pending.
struct RulesEditorView: View {
    let profile: Profile
    @Environment(SubscriptionService.self) private var service
    @Environment(MeowAPI.self) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var rules: [EditableRule] = []
    @State private var availableProxies: [String] = []
    @State private var presentedRule: EditableRule?
    @State private var presentingNewRule = false
    @State private var error: String?
    @State private var saving = false
    @State private var hasUnsavedChanges = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(rules) { rule in
                    rowButton(for: rule)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if rules.isEmpty {
                    ContentUnavailableView(
                        "rulesEditor.empty.title",
                        systemImage: "arrow.triangle.branch",
                        description: Text("rulesEditor.empty.description"),
                    )
                    .accessibilityIdentifier("rulesEditor.emptyState")
                }
            }
            .safeAreaInset(edge: .top) {
                if let error {
                    errorBanner(error)
                }
            }
            .navigationTitle("rulesEditor.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("rulesEditor.button.cancel") { dismiss() }
                        .accessibilityIdentifier("rulesEditor.cancelButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            presentingNewRule = true
                        } label: {
                            Label("rulesEditor.button.add", systemImage: "plus")
                        }
                        .accessibilityIdentifier("rulesEditor.addButton")
                        Button {
                            applyChinaPreset()
                        } label: {
                            Label(
                                "rulesEditor.button.addChinaPreset",
                                systemImage: "globe.asia.australia",
                            )
                        }
                        .accessibilityIdentifier("rulesEditor.addChinaPresetButton")
                    } label: {
                        Label("rulesEditor.button.add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("rulesEditor.addMenu")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        LocalizedStringKey(saving ? "rulesEditor.button.saving" : "rulesEditor.button.save"),
                        action: save,
                    )
                    .disabled(saving || !hasUnsavedChanges)
                    .accessibilityIdentifier("rulesEditor.saveButton")
                }
            }
            .sheet(item: $presentedRule) { rule in
                RuleEditorSheet(
                    availableProxies: availableProxies,
                    initial: rule,
                ) { updated in
                    apply(updated)
                }
            }
            .sheet(isPresented: $presentingNewRule) {
                let defaultProxy = availableProxies.first ?? "DIRECT"
                let newRule = EditableRule(type: "DOMAIN-SUFFIX", payload: "", proxy: defaultProxy)
                RuleEditorSheet(
                    availableProxies: availableProxies,
                    initial: newRule,
                ) { added in
                    // Insert above MATCH so the catch-all stays last; if
                    // there's no MATCH rule yet, just append.
                    if let matchIndex = rules.firstIndex(where: { $0.type.uppercased() == "MATCH" }) {
                        rules.insert(added, at: matchIndex)
                    } else {
                        rules.append(added)
                    }
                    hasUnsavedChanges = true
                }
            }
            .task { await loadInitial() }
            .onChange(of: error) { _, newValue in
                // The banner is inserted dynamically above the list;
                // announce it so VoiceOver users hear validation/save
                // failures without having to hunt for the new element.
                guard let newValue else { return }
                AccessibilityNotification.Announcement(
                    String(localized: "a11y.rulesEditor.error \(newValue)"),
                ).post()
            }
        }
    }

    // MARK: - Rows

    private func rowButton(for rule: EditableRule) -> some View {
        let index = rules.firstIndex(where: { $0.id == rule.id }) ?? 0
        return Button {
            presentedRule = rule
        } label: {
            HStack(spacing: 8) {
                Text(rule.type)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: .capsule)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("rulesEditor.row.\(index).type")
                Text(rule.payload.isEmpty ? "—" : rule.payload)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(
                        rule.payload.isEmpty ? Text("a11y.rulesEditor.row.payloadEmpty") : Text(rule.payload),
                    )
                    .accessibilityIdentifier("rulesEditor.row.\(index).payload")
                Spacer()
                Text(rule.proxy)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("a11y.rulesEditor.row.proxy \(rule.proxy)"))
                    .accessibilityIdentifier("rulesEditor.row.\(index).proxy")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rulesEditor.row.\(index)")
        .accessibilityHint(Text("a11y.rulesEditor.row.hint"))
        // Rule order decides match precedence, so surface the position —
        // it's the context VoiceOver users need when invoking the
        // move-up / move-down actions below.
        .accessibilityValue(Text("a11y.rulesEditor.row.position \(index + 1) \(rules.count)"))
        .accessibilityAction(named: Text("a11y.rulesEditor.row.moveUp")) {
            move(id: rule.id, by: -1)
        }
        .accessibilityAction(named: Text("a11y.rulesEditor.row.moveDown")) {
            move(id: rule.id, by: 1)
        }
        .accessibilityAction(named: Text("a11y.rulesEditor.row.delete")) {
            deleteRule(id: rule.id)
        }
    }

    // MARK: - Mutation

    private func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        hasUnsavedChanges = true
    }

    private func delete(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        hasUnsavedChanges = true
    }

    /// VoiceOver / Switch Control alternative to the edit-mode drag
    /// gesture: shift one rule a single position up (-1) or down (+1).
    private func move(id: UUID, by offset: Int) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = i + offset
        guard rules.indices.contains(target) else { return }
        rules.move(fromOffsets: IndexSet(integer: i), toOffset: offset > 0 ? target + 1 : target)
        hasUnsavedChanges = true
    }

    /// VoiceOver / Switch Control alternative to swipe-to-delete.
    private func deleteRule(id: UUID) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.remove(at: i)
        hasUnsavedChanges = true
    }

    private func apply(_ updated: EditableRule) {
        guard let i = rules.firstIndex(where: { $0.id == updated.id }) else { return }
        rules[i] = updated
        hasUnsavedChanges = true
    }

    /// Prepend the curated `ChinaDirectKeywords` preset to the rule list
    /// so the keyword rows match BEFORE any existing entries. Existing
    /// rows with the same (type, payload) are skipped — re-tapping the
    /// preset is a no-op rather than producing duplicates.
    ///
    /// Front-of-list placement is the whole point of the preset: meow
    /// walks `rules:` top-down and stops at the first match, so for the
    /// "send China-app traffic to DIRECT regardless of the user's other
    /// routing" intent to hold, these rows must precede everything else.
    /// The trailing `MATCH` (and any other prior rows) stay in their
    /// original order behind the preset.
    private func applyChinaPreset() {
        let preset = ChinaDirectKeywords.presetRules()
        let (merged, added) = ChinaDirectKeywords.prepend(preset: preset, to: rules)
        guard added > 0 else { return }
        rules = merged
        hasUnsavedChanges = true
    }

    // MARK: - I/O

    private func loadInitial() async {
        // Source rules — what the engine will load on its next start.
        // Errors here are user-visible (the active profile YAML is
        // unparseable) and there's nothing useful to fall back to, so we
        // surface them in the banner and leave the list empty.
        do {
            rules = try RulesYAMLEditor.load(from: profile.yamlContent)
        } catch {
            self.error = error.localizedDescription
        }

        // Best-effort proxy names. If the engine isn't running, the
        // picker degrades to a freeform text field — `RuleEditorSheet`
        // handles that automatically.
        if let resp = try? await api.getProxies() {
            availableProxies = resp.proxies.keys.sorted()
        }
    }

    private func save() {
        saving = true
        defer { saving = false }
        do {
            let newYAML = try RulesYAMLEditor.apply(rules, to: profile.yamlContent)
            try MeowConfigValidator.validate(newYAML)
            profile.yamlBackup = profile.yamlContent
            profile.yamlContent = newYAML
            try service.writeActiveConfig(profile)
            hasUnsavedChanges = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
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
        .accessibilityLabel(Text("a11y.rulesEditor.error \(message)"))
        .accessibilityIdentifier("rulesEditor.errorBanner")
    }
}
