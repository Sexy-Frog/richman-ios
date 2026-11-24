import Foundation

/// One HTTP response from the relay.
public struct RelayResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Transport abstraction for the onion relay.
///
/// The real implementation forces every request through the embedded Tor SOCKS
/// proxy (there is no clearnet fallback, by design — see RelayClient.kt). Keeping
/// it behind a protocol lets the protocol layer be unit-tested with a mock and lets
/// the Tor transport be added in a later increment without touching `RelayClient`.
public protocol RelayTransport: Sendable {
    /// Perform a request against `path` (relative, e.g. "v1/send") and return the
    /// raw response. `method` is "GET" or "POST". `contentType` is nil for GET.
    func perform(method: String, path: String, contentType: String?, body: Data?) async throws -> RelayResponse
}

public enum RelayError: Error, Equatable {
    case notConfigured
    case transportNotReady
    case http(Int, String)
    case badResponse(String)
}
