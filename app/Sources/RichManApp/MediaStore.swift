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
        PrivacyStorage.excludeFromBackup(url)
        return url
    }

    /// Decrypted copies handed to ShareLink/Quick Look. Kept out of backups and
    /// cleared on wipe/launch.
    static var exportsDirectory: URL {
        let url = directory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        PrivacyStorage.excludeFromBackup(url)
        return url
    }

    static func saveImage(_ data: Data) -> String? {
        guard let image = downsample(data, maxPixel: maxImagePixels) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        guard jpeg.count <= maxFileBytes else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try write(MediaCipher.seal(jpeg) ?? jpeg, named: name)
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
            try write(MediaCipher.seal(data) ?? data, named: stored)
            return (stored, data.count)
        } catch {
            return nil
        }
    }

    private static func write(_ data: Data, named name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        PrivacyStorage.excludeFromBackup(url)
    }

    private static let imageCache = NSCache<NSString, UIImage>()

    static func image(named name: String) -> UIImage? {
        if let hit = imageCache.object(forKey: name as NSString) { return hit }
        let url = directory.appendingPathComponent(name)
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let image: UIImage?
        if MediaCipher.isSealed(raw) {
            guard let plain = MediaCipher.open(raw) else { return nil }
            image = UIImage(data: plain)
        } else {
            image = UIImage(contentsOfFile: url.path)
        }
        if let image { imageCache.setObject(image, forKey: name as NSString) }
        return image
    }

    static func remove(_ name: String) {
        imageCache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(name)
        )
    }

    static func clearAll() {
        imageCache.removeAllObjects()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            MediaCipher.deleteKey()
            return
        }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
        MediaCipher.deleteKey()
    }

    /// For sealed files, decrypt into `Exports/` (excluded from backup) so
    /// ShareLink/Quick Look receives a normal file. Plaintext/demo files are
    /// returned directly.
    static func fileURL(named name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        guard let raw = try? Data(contentsOf: url),
              MediaCipher.isSealed(raw) else { return url }
        guard let plain = MediaCipher.open(raw) else { return url }
        let out = exportsDirectory.appendingPathComponent(name)
        try? plain.write(to: out, options: [.atomic, .completeFileProtection])
        PrivacyStorage.excludeFromBackup(out)
        return out
    }

    static func clearExports() {
        PrivacyStorage.removeTree(exportsDirectory)
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
            try write(MediaCipher.seal(data) ?? data, named: name)
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
