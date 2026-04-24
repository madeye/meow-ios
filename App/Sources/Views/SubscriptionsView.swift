import SwiftData
import SwiftUI

struct SubscriptionsView: View {
    @Environment(SubscriptionService.self) private var service
    @Query(sort: \Profile.lastUpdated, order: .reverse) private var profiles: [Profile]
    @State private var showingAdd = false
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
                        .accessibilityLabel("Edit YAML for \(profile.name)")
                        .accessibilityIdentifier("subscriptions.row.editYaml")
                        Button {
                            Task { try? await service.refresh(profile) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Refresh \(profile.name)")
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
        .navigationTitle("subscriptions.nav.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add subscription")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet(error: $error)
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
