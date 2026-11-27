import Foundation

/// Invite QR links.
///
/// The QR used to contain raw invite JSON, which a normal phone camera can only
/// show as text. It now contains a web link whose fragment carries the
/// base64url invite. Fragments never reach the server, so the relay never sees
/// the one-time key. The web page offers "open in app" (custom scheme) and a
/// copy button; the in-app scanner accepts the link, a bare token, or the raw
/// legacy JSON.
public enum InviteLink {
    public static let baseURLString = "https://kelvins.works/richman/invite.html"
    public static let scheme = "richman"

    public static func url(for invite: String) -> URL? {
        guard var components = URLComponents(string: baseURLString) else { return nil }
        components.fragment = Base64URL.encode(Data(invite.utf8))
        return components.url
    }

    public static func appURL(for invite: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "invite"
        components.fragment = Base64URL.encode(Data(invite.utf8))
        return components.url
    }

    /// Accepts raw invite JSON, our invite URL, `richman://invite#…`, or a bare
    /// base64url token. Returns the raw invite JSON for `addFriend`.
    public static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") { return trimmed }

        if let url = URL(string: trimmed),
           let fragment = url.fragment,
           !fragment.isEmpty,
           let raw = decodeToken(fragment) {
            return raw
        }
        return decodeToken(trimmed)
    }

    private static func decodeToken(_ token: String) -> String? {
        guard let data = try? Base64URL.decode(token),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("{") else {
            return nil
        }
        return text
    }
}
