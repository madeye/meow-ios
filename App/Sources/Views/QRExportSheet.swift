import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a share-link payload as a QR code image. CoreImage emits a
/// 1pt-per-module bitmap; callers scale it up with interpolation disabled so
/// the modules stay crisp.
enum QRCodeRenderer {
    static func image(for payload: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Shows one or more share-link payloads as scannable QR codes — a profile's
/// Clash subscription URL, or the `ss://` URIs of the locally added
/// Shadowsocks servers. Multiple payloads (one per server) get a picker.
struct QRExportSheet: View {
    struct Payload: Identifiable, Equatable, Hashable {
        var title: String
        var text: String

        var id: String {
            title + "\n" + text
        }
    }

    enum Kind {
        case subscriptionURL
        case shadowsocksURI
    }

    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let payloads: [Payload]
    @State private var selection: Payload?
    @State private var copied = false

    init(kind: Kind, payloads: [Payload]) {
        self.kind = kind
        self.payloads = payloads
        _selection = State(initialValue: payloads.first)
    }

    private var current: Payload? {
        selection ?? payloads.first
    }

    private var captionKey: LocalizedStringKey {
        switch kind {
        case .subscriptionURL: "qrExport.caption.subscription"
        case .shadowsocksURI: "qrExport.caption.shadowsocks"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let payload = current {
                    payloadView(payload)
                } else {
                    // Only reachable if the generated profile's YAML was
                    // hand-edited down to zero ss proxies.
                    Text("qrExport.empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.screenBackground)
            .navigationTitle("qrExport.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.close") { dismiss() }
                        .accessibilityIdentifier("qrExport.closeButton")
                }
            }
        }
    }

    private func payloadView(_ payload: Payload) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                if payloads.count > 1 {
                    serverPicker
                }
                qrImage(payload)
                payloadText(payload)
                actionButtons(payload)
                Text(captionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
    }

    private var serverPicker: some View {
        Picker("qrExport.picker.server", selection: $selection) {
            ForEach(payloads) { item in
                Text(item.title).tag(Optional(item))
            }
        }
        .pickerStyle(.menu)
        .tint(AppTheme.accent)
        .accessibilityIdentifier("qrExport.serverPicker")
    }

    @ViewBuilder
    private func qrImage(_ payload: Payload) -> some View {
        if let image = QRCodeRenderer.image(for: payload.text) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: 280)
                // QR quiet zone: always white behind dark modules so
                // scanners keep contrast in dark mode too.
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(Text("qrExport.a11y.qrImage \(payload.title)"))
                .accessibilityIdentifier("qrExport.qrImage")
        } else {
            // A payload can exceed QR capacity (~2.9 KB at level M) —
            // e.g. a very long subscription URL. Copying still works.
            Text("qrExport.error.tooLong")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func payloadText(_ payload: Payload) -> some View {
        Text(payload.text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(6)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                AppTheme.panel,
                in: RoundedRectangle(cornerRadius: 12),
            )
            .accessibilityIdentifier("qrExport.payloadText")
    }

    private func actionButtons(_ payload: Payload) -> some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = payload.text
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(
                    copied ? "qrExport.button.copied" : "qrExport.button.copy",
                    systemImage: copied ? "checkmark" : "doc.on.doc",
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .tint(AppTheme.accent)
            .accessibilityIdentifier("qrExport.copyButton")

            ShareLink(item: payload.text) {
                Label("qrExport.button.share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .tint(AppTheme.accent)
            .accessibilityIdentifier("qrExport.shareButton")
        }
    }
}
