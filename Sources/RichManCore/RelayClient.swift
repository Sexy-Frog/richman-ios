import Foundation

/// One message returned by `/v1/fetch`: its relay id (for ack) and the raw envelope.
public struct FetchedMessage: Equatable {
    public let id: String
    public let envelope: Data
    public init(id: String, envelope: Data) {
        self.id = id
        self.envelope = envelope
    }
}

/// Typed client for the onion relay `/v1` API (docs/PROTOCOL.md §4).
/// Transport-agnostic: all I/O goes through a `RelayTransport` (Tor in production).
public final class RelayClient {

    private static let jsonType = "application/json; charset=utf-8"
    private static let binType = "application/octet-stream"

    private let transport: RelayTransport

    public init(transport: RelayTransport) {
        self.transport = transport
    }

    // MARK: Invites

    /// Upload a prekey bundle, returns the one-time token (15 min, single fetch).
    public func putInvite(bundle: Data) async throws -> String {
        let resp = try await postRaw("v1/invite", body: bundle, contentType: Self.binType)
        return try string(resp, "token")
    }

    /// Fetch and consume a prekey bundle by token (relay deletes it on fetch).
    public func fetchInvite(token: String) async throws -> Data {
        let body = try jsonBody(["token": token])
        let resp = try await postRaw("v1/invite/fetch", body: body, contentType: Self.jsonType)
        return resp.body
    }

    // MARK: Messages

    public func send(to box: Data, envelope: Data) async throws {
        precondition(box.count == 32)
        let body = try jsonBody(["to": Base64URL.encode(box), "env": Base64URL.encode(envelope)])
        _ = try await postRaw("v1/send", body: body, contentType: Self.jsonType)
    }

    /// Long-poll for queued messages (wait 0..25 seconds).
    public func fetch(box: Data, wait waitSeconds: Int = 20) async throws -> [FetchedMessage] {
        precondition(box.count == 32)
        let body = try jsonBody(["box": Base64URL.encode(box), "wait": waitSeconds])
        let resp = try await postRaw("v1/fetch", body: body, contentType: Self.jsonType)
        let obj = try jsonObject(resp.body)
        guard let arr = obj["msgs"] as? [[String: Any]] else { return [] }
        var out: [FetchedMessage] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            guard let id = item["id"] as? String, let env = item["env"] as? String else {
                throw RelayError.badResponse("malformed msg item")
            }
            out.append(FetchedMessage(id: id, envelope: try Base64URL.decode(env)))
        }
        return out
    }

    public func ack(box: Data, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        precondition(box.count == 32)
        let body = try jsonBody(["box": Base64URL.encode(box), "ids": ids])
        _ = try await postRaw("v1/ack", body: body, contentType: Self.jsonType)
    }

    // MARK: Blobs

    public func putBlob(_ data: Data) async throws -> String {
        let resp = try await postRaw("v1/blob", body: data, contentType: Self.binType)
        return try string(resp, "id")
    }

    /// Fetch and consume a blob (relay deletes it on fetch). The id is bounded
    /// to base64url so a peer-supplied value cannot inject path segments.
    public func getBlob(id: String) async throws -> Data {
        guard !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { throw RelayError.badResponse("bad blob id") }
        let resp = try await transport.perform(method: "GET", path: "v1/blob/\(id)", contentType: nil, body: nil)
        guard resp.isSuccess else { throw RelayError.http(resp.status, "blob") }
        return resp.body
    }

    // MARK: Map / health

    public func getTile(z: Int, x: Int, y: Int) async throws -> Data? {
        let resp = try await transport.perform(method: "GET", path: "v1/tile/\(z)/\(x)/\(y)", contentType: nil, body: nil)
        return resp.isSuccess ? resp.body : nil
    }

    public func getMapResource(path: String) async throws -> Data? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let resp = try await transport.perform(method: "GET", path: "v1/map/\(trimmed)", contentType: nil, body: nil)
        return resp.isSuccess ? resp.body : nil
    }

    public func ping() async throws -> Bool {
        let resp = try await transport.perform(method: "GET", path: "healthz", contentType: nil, body: nil)
        return resp.isSuccess
    }

    // MARK: plumbing

    private func postRaw(_ path: String, body: Data, contentType: String) async throws -> RelayResponse {
        let resp = try await transport.perform(method: "POST", path: path, contentType: contentType, body: body)
        guard resp.isSuccess else {
            let snippet = String(data: resp.body.prefix(160), encoding: .utf8) ?? ""
            throw RelayError.http(resp.status, snippet)
        }
        return resp
    }

    private func jsonBody(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayError.badResponse("expected JSON object")
        }
        return obj
    }

    private func string(_ resp: RelayResponse, _ key: String) throws -> String {
        let obj = try jsonObject(resp.body)
        guard let v = obj[key] as? String else { throw RelayError.badResponse("missing \(key)") }
        return v
    }
}
