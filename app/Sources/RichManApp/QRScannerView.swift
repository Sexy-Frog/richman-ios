import SwiftUI
import VisionKit

/// Camera QR scanner (device only; the Simulator has no camera). The parent
/// closes the sheet and feeds the payload into the normal invite validation.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return
        }
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let parent: QRScannerView
        private var handled = false

        init(_ parent: QRScannerView) {
            self.parent = parent
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !handled else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let value = barcode.payloadStringValue {
                    handled = true
                    parent.onCode(value)
                    return
                }
            }
        }
    }
}
