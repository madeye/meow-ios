import SwiftData
import SwiftUI

struct SubscriptionsView: View {
    @Environment(SubscriptionService.self) private var service
    @Query(sort: \Profile.lastUpdated, order: .reverse) private var profiles: [Profile]
    @State private var showingAdd = false
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
                            Text("Updated \(profile.lastUpdated, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { try? await service.refresh(profile) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
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
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet(error: $error)
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
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
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "Adding…" : "Add") {
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
