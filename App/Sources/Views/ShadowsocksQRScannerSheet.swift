import AVFoundation
import SwiftUI
import VisionKit

/// Camera sheet that scans a QR code and hands the payload string back.
/// VisionKit's `DataScannerViewController` needs a physical camera — on
/// Simulator / Mac the sheet degrades to a hint to paste the link instead
/// (every iOS 17 device has the required A12+ hardware, so on-device
/// availability is gated only by camera permission).
struct ShadowsocksQRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    private enum CameraState {
        case checking
        case ready
        case denied
        case unsupported
    }

    @State private var cameraState: CameraState = .checking

    var body: some View {
        NavigationStack {
            Group {
                switch cameraState {
                case .checking:
                    ProgressView()
                case .ready:
                    QRCodeDataScanner { payload in
                        onScan(payload)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                case .denied:
                    ContentUnavailableView(
                        "ssAdd.scanner.unavailable.title",
                        systemImage: "camera",
                        description: Text("ssAdd.scanner.denied.description"),
                    )
                case .unsupported:
                    ContentUnavailableView(
                        "ssAdd.scanner.unavailable.title",
                        systemImage: "camera",
                        description: Text("ssAdd.scanner.unavailable.description"),
                    )
                }
            }
            .navigationTitle("ssAdd.scanner.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .accessibilityIdentifier("ssAdd.scanner.cancelButton")
                }
            }
            .task { await resolveCameraState() }
        }
    }

    private func resolveCameraState() async {
        guard DataScannerViewController.isSupported else {
            cameraState = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraState = granted ? .ready : .denied
        default:
            cameraState = .denied
        }
    }
}

private struct QRCodeDataScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true,
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context _: Context) {
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator _: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _: DataScannerViewController,
            didAdd added: [RecognizedItem],
            allItems _: [RecognizedItem],
        ) {
            guard !delivered else { return }
            for item in added {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    delivered = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}
