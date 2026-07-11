import SwiftUI

/// Confirmation shown before a `meow://connect` deep link is allowed to
/// fetch or activate anything (issue #293). Import-only is the primary,
/// safe-by-default action; "Import & Activate" only appears when the deep
/// link requested `select=1`, and even then it takes a separate, explicit
/// tap — the link's `select=1` never activates a profile by itself.
struct DeepLinkConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedInsecureTransport = false
    let confirmation: DeepLinkImportConfirmation
    let onAction: (DeepLinkConfirmationAction) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("deepLinkImport.field.name", value: confirmation.name)
                    LabeledContent("deepLinkImport.field.host", value: confirmation.host)
                    Text(confirmation.subscriptionURL.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            Text("deepLinkImport.a11y.url \(confirmation.subscriptionURL.absoluteString)"),
                        )
                } header: {
                    Text("deepLinkImport.section.subscription")
                }

                if confirmation.isInsecure {
                    Section {
                        Label("deepLinkImport.warning.insecure", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.warning)
                        Toggle(
                            "deepLinkImport.warning.acknowledge",
                            isOn: $acknowledgedInsecureTransport,
                        )
                        .accessibilityIdentifier("deepLinkImport.insecureAcknowledgement")
                    }
                }

                if confirmation.isDuplicate {
                    Section {
                        Text("deepLinkImport.notice.duplicate")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        onAction(.importOnly)
                        dismiss()
                    } label: {
                        Text(confirmation.isDuplicate
                            ? "deepLinkImport.button.update"
                            : "deepLinkImport.button.import")
                    }
                    .disabled(confirmation.isInsecure && !acknowledgedInsecureTransport)
                    .accessibilityIdentifier("deepLinkImport.importButton")

                    if confirmation.requestsActivation {
                        Button {
                            onAction(.importAndActivate)
                            dismiss()
                        } label: {
                            Text("deepLinkImport.button.importAndActivate")
                        }
                        .disabled(confirmation.isInsecure && !acknowledgedInsecureTransport)
                        .accessibilityIdentifier("deepLinkImport.importAndActivateButton")
                    }
                }
            }
            .navigationTitle("deepLinkImport.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        onAction(.cancel)
                        dismiss()
                    }
                    .accessibilityIdentifier("deepLinkImport.cancelButton")
                    .accessibilityLabel(String(localized: "a11y.deepLinkImport.cancel"))
                }
            }
            .onAppear {
                AccessibilityNotification.ScreenChanged().post()
            }
        }
    }
}
