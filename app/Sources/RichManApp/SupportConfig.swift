import Foundation

/// Public support/privacy destinations used by the App Store listing, the
/// in-app policy, and the UGC report flow. Change these in one place.
enum SupportConfig {
    /// Monitored support mailbox. App Review 1.2 requires a reachable contact.
    static let email = "support@kelvins.works"

    static let supportURL = URL(string: "https://kelvins.works/richman/support.html")!
    static let privacyURL = URL(string: "https://kelvins.works/richman/privacy.html")!

    /// `mailto:` URL with a prefilled reason and the peer's public id.
    static func reportMailURL(reason: String, peerId: String) -> URL? {
        let body = """
        通報理由: \(reason)
        相手の公開ID: \(peerId)
        アプリ: RichMan iOS
        日時: \(Date().formatted())
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "RichMan 通報: \(reason)"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
