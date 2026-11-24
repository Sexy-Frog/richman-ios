import XCTest
import Foundation
import LibSignalClient
@testable import RichManCrypto

/// The first thing to trust on macOS CI: a full offline X3DH + PQXDH handshake
/// and double-ratchet round-trip between two in-memory identities, using the
/// SAME invite-bundle JSON + `[type byte][ciphertext]` framing the Android app
/// uses. If this passes, the libsignal 0.86.5 FFI is wired correctly and the
/// iOS crypto layer speaks the Android protocol.
final class CryptoHandshakeTests: XCTestCase {

    private func u8(_ t: CiphertextMessage.MessageType) -> UInt8 { t.rawValue }

    func testBundleHasAndroidShape() throws {
        let km = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        let obj = try JSONSerialization.jsonObject(with: try km.buildBundle(displayName: "A")) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["id"] as? String, km.id)
        XCTAssertNotNil(obj["reg"] as? Int)
        for k in ["spk", "kpk"] {
            let o = obj[k] as! [String: Any]
            XCTAssertNotNil(o["i"] as? Int); XCTAssertNotNil(o["p"] as? String); XCTAssertNotNil(o["s"] as? String)
        }
        let opk = obj["opk"] as! [String: Any]
        XCTAssertNotNil(opk["i"] as? Int); XCTAssertNotNil(opk["p"] as? String)
        XCTAssertNil(opk["s"])   // one-time prekey is unsigned
    }

    func testFullHandshakeAndRatchet() throws {
        // A = inviter (publishes a bundle); B = scanner (processes it, sends first).
        let a = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        let b = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        XCTAssertNotEqual(a.id, b.id)

        let aBundle = try a.buildBundle(displayName: "Alice")
        try b.startSession(peerId: a.id, bundle: aBundle)
        XCTAssertTrue(b.hasSession(peerId: a.id))

        // B → A: the very first message is a PreKey message.
        let c1 = try b.encrypt(peerId: a.id, plaintext: Data("こんにちは".utf8))
        XCTAssertEqual([UInt8](c1).first, u8(.preKey))

        // A can recover B's identity from the PreKey message before it knows B.
        XCTAssertEqual(a.peekPreKeyIdentity(payload: c1), b.id)

        let p1 = try a.decrypt(peerId: b.id, payload: c1)
        XCTAssertEqual(String(decoding: p1, as: UTF8.self), "こんにちは")
        XCTAssertTrue(a.hasSession(peerId: b.id))

        // A → B: now a normal (whisper) ratchet message, decodes on B.
        let c2 = try a.encrypt(peerId: b.id, plaintext: Data("やあ".utf8))
        XCTAssertEqual([UInt8](c2).first, u8(.whisper))
        XCTAssertEqual(String(decoding: try b.decrypt(peerId: a.id, payload: c2), as: UTF8.self), "やあ")

        // B → A again: session established, so this is whisper (not preKey).
        let c3 = try b.encrypt(peerId: a.id, plaintext: Data("again".utf8))
        XCTAssertEqual([UInt8](c3).first, u8(.whisper))
        XCTAssertEqual(String(decoding: try a.decrypt(peerId: b.id, payload: c3), as: UTF8.self), "again")
    }

    func testIdentityMismatchRejected() throws {
        let a = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        let b = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        // Claiming A's bundle under B's id must fail the identity check.
        XCTAssertThrowsError(try b.startSession(peerId: b.id, bundle: try a.buildBundle(displayName: "A")))
    }
}
