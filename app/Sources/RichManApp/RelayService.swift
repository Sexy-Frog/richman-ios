import Foundation
import RichManCore

/// Wires the app to the relay using the CI-verified RichManCore pipeline:
///  - outgoing: rb-stamp → crypto.encrypt → Wire v2 seal → RelayClient.send(to: box)
///  - incoming: RelayClient.fetch(box) → IncomingOpener → decrypted payloads, then ack
///
/// The transport is injected: the Tor SOCKS transport on device, a stub in the
/// Simulator (no network). This is the single place real send/receive happens;
/// the UI drives it through `ChatStore`.
actor RelayService {
    private let client: RelayClient
    private let crypto: CryptoEngine

    init(transport: RelayTransport, crypto: CryptoEngine) {
        self.client = RelayClient(transport: transport)
        self.crypto = crypto
    }

    /// Seal a payload (stamping my reply mailbox) and send it to a peer's mailbox.
    func send(payload: Data, to peerId: String, box: Data, replyBox: String) async throws {
        let envelope = try OutgoingSealer.seal(payload: payload, replyBox: replyBox, to: peerId, crypto: crypto)
        try await client.send(to: box, envelope: envelope)
    }

    /// Poll one mailbox once, open what's there, and ack it. `knownSender` is the
    /// contact that owns this mailbox (nil for an invite mailbox → PreKey peek).
    @discardableResult
    func poll(box: Data, knownSender: String?, wait: Int = 0) async throws -> [OpenedMessage] {
        let fetched = try await client.fetch(box: box, wait: wait)
        guard !fetched.isEmpty else { return [] }
        var opened: [OpenedMessage] = []
        for m in fetched {
            if let o = try? IncomingOpener.open(envelope: m.envelope, knownSender: knownSender, crypto: crypto) {
                opened.append(o)
            }
        }
        try? await client.ack(box: box, ids: fetched.map(\.id))
        return opened
    }

    func reachable() async -> Bool { (try? await client.ping()) ?? false }
}

/// Simulator / no-network transport: every request fails politely so the UI keeps
/// working without a relay. The Tor transport replaces this on device.
struct StubRelayTransport: RelayTransport {
    func perform(method: String, path: String, contentType: String?, body: Data?) async throws -> RelayResponse {
        RelayResponse(status: 503, body: Data())
    }
}
