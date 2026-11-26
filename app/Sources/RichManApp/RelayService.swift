import Foundation
import RichManCore

/// Wires the app to the relay using the CI-verified RichManCore pipeline:
///  - outgoing: rb-stamp → crypto.encrypt → Wire v2 seal → RelayClient.send(to: box)
///  - incoming: RelayClient.fetch(box) → IncomingOpener → decrypted payloads, then ack
///
/// The transport is injected: the Tor SOCKS transport on device, a stub in the
/// Simulator (no network). This is the single place real send/receive happens;
/// the UI drives it through `ChatStore`.
///
/// Each mailbox gets a distinct SOCKS username so Tor's `IsolateSOCKSAuth`
/// places different contacts on different circuits. Without this the relay
/// could link every mailbox by seeing one shared circuit.
actor RelayService {
    private let transportFor: @Sendable (String) -> RelayTransport
    private let crypto: CryptoEngine

    init(
        transportFactory: @escaping @Sendable (String) -> RelayTransport,
        crypto: CryptoEngine
    ) {
        self.transportFor = transportFactory
        self.crypto = crypto
    }

    /// Single-transport compatibility path (E2E host Tor, tests).
    init(transport: RelayTransport, crypto: CryptoEngine) {
        self.init(transportFactory: { _ in transport }, crypto: crypto)
    }

    private func client(_ isolation: String) -> RelayClient {
        RelayClient(transport: transportFor(isolation))
    }

    private func isolation(for box: Data) -> String {
        "m:" + Base64URL.encode(box)
    }

    /// Seal a payload (stamping my reply mailbox) and send it to a peer's mailbox.
    func send(payload: Data, to peerId: String, box: Data, replyBox: String) async throws {
        let envelope = try OutgoingSealer.seal(
            payload: payload,
            replyBox: replyBox,
            to: peerId,
            crypto: crypto
        )
        try await client(isolation(for: box)).send(to: box, envelope: envelope)
    }

    /// Poll one mailbox once, open what's there, and ack it. `knownSender` is the
    /// contact that owns this mailbox (nil for an invite mailbox → PreKey peek).
    @discardableResult
    func poll(box: Data, knownSender: String?, wait: Int = 0) async throws -> [OpenedMessage] {
        let relay = client(isolation(for: box))
        let fetched = try await relay.fetch(box: box, wait: wait)
        guard !fetched.isEmpty else { return [] }
        var opened: [OpenedMessage] = []
        for m in fetched {
            if let o = try? IncomingOpener.open(
                envelope: m.envelope,
                knownSender: knownSender,
                crypto: crypto
            ) {
                opened.append(o)
            }
        }
        try? await relay.ack(box: box, ids: fetched.map(\.id))
        return opened
    }

    /// Blob traffic is isolated separately from message mailboxes. `isolation`
    /// should be stable per peer/group, never a random value per call.
    func putBlob(_ data: Data, isolation: String) async throws -> String {
        try await client("b:" + isolation).putBlob(data)
    }

    func getBlob(id: String, isolation: String) async throws -> Data {
        try await client("b:" + isolation).getBlob(id: id)
    }

    func reachable() async -> Bool {
        (try? await client("health").ping()) ?? false
    }
}

/// Simulator / no-network transport: every request fails politely so the UI keeps
/// working without a relay. The Tor transport replaces this on device.
struct StubRelayTransport: RelayTransport {
    func perform(method: String, path: String, contentType: String?, body: Data?) async throws -> RelayResponse {
        RelayResponse(status: 503, body: Data())
    }
}
