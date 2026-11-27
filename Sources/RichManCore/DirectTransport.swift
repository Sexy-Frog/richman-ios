import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Clearnet (HTTPS) transport to the relay.
///
/// Used by the default "direct" mode so sending/receiving and APNs
/// registration do not wait for a Tor bootstrap. TLS protects the transport;
/// message bodies are already sealed end-to-end. The relay can see the device
/// IP in this mode, which is disclosed in Settings and the privacy policy.
public final class DirectTransport: RelayTransport, @unchecked Sendable {
    private let base: String
    private let session: URLSession

    public init(baseURL: URL) {
        var text = baseURL.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        base = text

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func perform(
        method: String,
        path: String,
        contentType: String?,
        body: Data?
    ) async throws -> RelayResponse {
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? path
        guard let url = URL(string: base + encoded) else {
            throw RelayError.badResponse("bad path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return RelayResponse(status: status, body: data)
    }
}
