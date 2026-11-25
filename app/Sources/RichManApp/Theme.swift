import SwiftUI
import UIKit

/// Signal-blue palette, ported 1:1 from the Android `ui/Theme.kt` (which in turn
/// matches the web app's CSS `:root`). Light/dark resolve automatically.
enum Brand {
    static let signalBlue = Color(hex: 0x3A76F0)
    static let signalBlueDark = Color(hex: 0x2C62D6)
}

/// Semantic tokens used across the app (adaptive to light/dark).
enum RM {
    static let primary = Brand.signalBlue
    static let onPrimary = Color.white
    static let secondary = Color.adaptive(light: 0x3B82F6, dark: 0x7DD3FC)

    static let background = Color.adaptive(light: 0xF2F4F6, dark: 0x0E1114)
    static let onBackground = Color.adaptive(light: 0x111315, dark: 0xE8EAED)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x161B1F)
    static let onSurface = Color.adaptive(light: 0x111315, dark: 0xE8EAED)
    static let surfaceVariant = Color.adaptive(light: 0xEEF1F4, dark: 0x1E252B)
    static let onSurfaceVariant = Color.adaptive(light: 0x6B7280, dark: 0x9AA4AE)
    static let outline = Color.adaptive(light: 0xE6E9ED, dark: 0x2B343C)
    static let error = Color.adaptive(light: 0xD93025, dark: 0xF87171)

    // Chat surfaces (no Material slot on Android — consumed directly).
    static let chatBg = Color.adaptive(light: 0xE7EBEF, dark: 0x0B0E11)
    static let bubbleMe = Brand.signalBlue
    static let bubbleMeText = Color.white
    static let bubbleThem = Color.adaptive(light: 0xFFFFFF, dark: 0x242B31)
    static let bubbleThemText = Color.adaptive(light: 0x111315, dark: 0xE8EAED)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// A color that resolves light/dark at render time (iOS dynamic UIColor).
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
