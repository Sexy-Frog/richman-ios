import UIKit
import CoreImage.CIFilterBuiltins

/// Renders a string (our invite payload) as a crisp QR image. Generation works
/// everywhere incl. the Simulator; camera *scanning* is device-only and lands
/// later (AddFriend keeps a paste field as the Simulator path).
enum QRCode {
    private static let context = CIContext()

    static func image(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up so the QR is sharp (CIQRCodeGenerator renders 1px per module).
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
