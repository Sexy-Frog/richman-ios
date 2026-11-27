import UIKit
import CoreImage.CIFilterBuiltins

/// Renders an invite string as a QR with the RichMan mark in the middle.
/// The mark is ~22% of the code and error correction is "H", so it stays
/// scannable for normal phone cameras.
enum QRCode {
    private static let context = CIContext()

    static func image(from string: String, size: CGFloat = 720) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let qr = UIImage(cgImage: cg)
        return withMark(qr, size: size)
    }

    private static func withMark(_ qr: UIImage, size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: format
        )
        return renderer.image { _ in
            qr.draw(in: CGRect(x: 0, y: 0, width: size, height: size))

            let mark = size * 0.22
            let rect = CGRect(
                x: (size - mark) / 2,
                y: (size - mark) / 2,
                width: mark,
                height: mark
            )
            let plate = rect.insetBy(dx: -mark * 0.10, dy: -mark * 0.10)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: plate, cornerRadius: mark * 0.30).fill()

            UIColor(red: 0x3A / 255, green: 0x76 / 255, blue: 0xF0 / 255, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: mark * 0.24).fill()

            let text = "R" as NSString
            let font = UIFont.systemFont(ofSize: mark * 0.58, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2
                ),
                withAttributes: attributes
            )
        }
    }
}
