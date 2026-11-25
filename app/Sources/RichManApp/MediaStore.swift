import Foundation
import UIKit
import ImageIO

/// Local media store for chat attachments. Files live in Application Support
/// with complete file protection; images are downsampled before writing so a
/// hostile image cannot exhaust memory.
enum MediaStore {
    private static let maxImagePixels = 1600
    private static let maxFileBytes = 10 * 1024 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func saveImage(_ data: Data) -> String? {
        guard let image = downsample(data, maxPixel: maxImagePixels) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        guard jpeg.count <= maxFileBytes else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(
                to: directory.appendingPathComponent(name),
                options: [.atomic, .completeFileProtection]
            )
            return name
        } catch {
            return nil
        }
    }

    static func saveFile(_ url: URL) -> (name: String, size: Int, data: Data)? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let saved = saveFileData(data, name: url.lastPathComponent) else {
                return nil
            }
            return (saved.name, saved.size, data)
        } catch {
            return nil
        }
    }

    /// Store decrypted media received from a peer. The name is reduced to its
    /// last path component so a hostile `name` cannot escape the media dir.
    static func saveFileData(_ data: Data, name: String) -> (name: String, size: Int)? {
        guard data.count <= maxFileBytes else { return nil }
        let base = URL(fileURLWithPath: name).lastPathComponent
        let safe = base.isEmpty ? "file" : base
        let stored = UUID().uuidString + "-" + safe
        do {
            try data.write(
                to: directory.appendingPathComponent(stored),
                options: [.atomic, .completeFileProtection]
            )
            return (stored, data.count)
        } catch {
            return nil
        }
    }

    static func image(named name: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }

    static func clearAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func demoImage() -> String? {
        let name = "demo-welcome.jpg"
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }

        let size = CGSize(width: 640, height: 420)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let colors = [UIColor(hex: 0x3A76F0).cgColor, UIColor(hex: 0x7DD3FC).cgColor]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            let text = "RichMan" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 52),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2
                ),
                withAttributes: attributes
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return name
        } catch {
            return nil
        }
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
