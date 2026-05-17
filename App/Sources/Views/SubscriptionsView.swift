import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SubscriptionsView: View {
    @Environment(SubscriptionService.self) private var service
    @Query(sort: \Profile.lastUpdated, order: .reverse) private var profiles: [Profile]
    @State private var showingAdd = false
    @State private var showingImporter = false
    @State private var editing: Profile?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(profiles) { profile in
                GlassCard {
                    HStack {
                        Image(systemName: profile.isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(profile.isSelected ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text(
                                "subscriptions.row.updatedAgo \(profile.lastUpdated, style: .relative)",
                                comment: "Subscription row subtitle; %@ = relative time since last update",
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            editing = profile
                        } label: {
                            Image(systemName: "pencil")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("subscriptions.row.a11y.edit \(profile.name)"))
                        .accessibilityIdentifier("subscriptions.row.editYaml")
                        if !profile.url.isEmpty {
                            Button {
                                Task { try? await service.refresh(profile) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("subscriptions.row.a11y.refresh \(profile.name)"))
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                .onTapGesture { try? service.select(profile) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        try? service.delete(profile)
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.screenBackground)
        .overlay {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "subscriptions.empty.title",
                    systemImage: "tray",
                    description: Text("subscriptions.empty.description"),
                )
                .accessibilityIdentifier("subscriptions.emptyState")
            }
        }
        .navigationTitle("subscriptions.nav.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("subscriptions.toolbar.addFromURL", systemImage: "link")
                    }
                    .accessibilityIdentifier("subscriptions.toolbar.addFromURL")

                    Button {
                        showingImporter = true
                    } label: {
                        Label("subscriptions.toolbar.importFromFile", systemImage: "icloud.and.arrow.down")
                    }
                    .accessibilityIdentifier("subscriptions.toolbar.importFromFile")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("subscriptions.toolbar.a11y.add"))
                .accessibilityIdentifier("subscriptions.toolbar.add")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet(error: $error)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: yamlContentTypes(),
            allowsMultipleSelection: false,
        ) { result in
            handleImport(result)
        }
        .sheet(item: $editing) { profile in
            NavigationStack {
                YamlEditorView(profile: profile)
            }
        }
        .alert("common.error", isPresented: .constant(error != nil)) {
            Button("common.ok") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// File picker accepts YAML proper plus `.txt` and unspecified data —
    /// iCloud Drive routinely serves Clash configs uploaded from desktops
    /// where the OS tagged them as `public.plain-text` or just `public.data`,
    /// not `public.yaml`. The actual YAML check happens inside addLocal's
    /// normalize step, so widening the accept list here is safe.
    private func yamlContentTypes() -> [UTType] {
        var types: [UTType] = [.yaml, .plainText, .text, .data]
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let yaml = try await readSecurityScoped(url)
                    let suggestedName = url.deletingPathExtension().lastPathComponent
                    let name = suggestedName.isEmpty ? "Imported" : suggestedName
                    _ = try await service.addLocal(name: name, yamlContent: yaml)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        case let .failure(err):
            error = err.localizedDescription
        }
    }

    /// iCloud Drive / Files picker hands back a URL that requires a
    /// security-scoped resource access pairing before the sandbox lets us
    /// read it. The picker URL is single-shot — we copy the bytes into a
    /// String and let the scope expire.
    private func readSecurityScoped(_ url: URL) async throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SubscriptionsView",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                    "subscriptions.import.invalidEncoding",
                    comment: "Shown when an imported file isn't UTF-8 text",
                )],
            )
        }
        return yaml
    }
}

private struct AddSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    @Binding var error: String?
    @State private var name = ""
    @State private var url = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("subscriptions.add.field.name", text: $name)
                    TextField("subscriptions.add.field.url", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("subscriptions.add.nav.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(
                        submitting ? "subscriptions.add.button.adding" : "subscriptions.add.button.add",
                    )) {
                        submitting = true
                        Task {
                            do {
                                _ = try await service.add(name: name, url: url)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            submitting = false
                        }
                    }
                    .disabled(name.isEmpty || url.isEmpty || submitting)
                }
            }
        }
    }
}
