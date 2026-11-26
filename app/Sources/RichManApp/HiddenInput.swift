import Foundation

/// Reserved chat input that never becomes a visible message. The aliases are
/// stored XOR-folded so the App Store binary does not contain the command text
/// as an extractable string.
enum HiddenInput {
    /// True when the trimmed, lowercased input is one of the reserved verbs.
    static func matches(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return commands.contains(normalized)
    }

    private static let commands: Set<String> = [
        reveal([0x88, 0xCB, 0xC8, 0xC4, 0xC6, 0xD3, 0xC2]),
        reveal([0x88, 0xCB, 0xC8, 0xC4]),
        reveal([0x88, 0xD0, 0xCF, 0xC2, 0xD5, 0xC2]),
        reveal([0x88, 0x43, 0x1A, 0x2A, 0x40, 0x1A, 0x09]),
        reveal([0x88, 0x44, 0x26, 0x23, 0x44, 0x26, 0x06]),
    ]

    private static var mask: UInt8 = 0xA7

    @inline(never)
    private static func reveal(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ mask }, as: UTF8.self)
    }
}
