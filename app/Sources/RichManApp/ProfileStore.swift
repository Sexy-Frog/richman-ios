import SwiftUI
import UIKit

/// Local profile icon. Stored as a JPEG in Application Support (which the app
/// excludes from backups) and never uploaded; contacts still see the name.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var avatar: UIImage?

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        fileURL = base.appendingPathComponent("avatar.jpg", isDirectory: false)
        load()
    }

    func setAvatar(_ image: UIImage) {
        let resized = Self.resized(image, maxSide: 512)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return }
        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            avatar = UIImage(data: data)
        } catch {
            // Keep the previous icon if the write fails.
        }
    }

    func removeAvatar() {
        try? FileManager.default.removeItem(at: fileURL)
        avatar = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        avatar = UIImage(data: data)
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let target = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
