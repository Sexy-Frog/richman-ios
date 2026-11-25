import XCTest
@testable import RichManCore

/// A no-crypto CryptoEngine: encrypt prepends a fake type byte, decrypt strips
/// it (so encrypt/decrypt are inverses), and peek returns a configurable sender.
private final class MockEngine: CryptoEngine {
    let myId = "ME"
    private let typeByte: UInt8
    private let peekId: String?
    init(typeByte: UInt8 = 0x02, peekId: String? = "PEER-PEEK") {
        self.typeByte = typeByte; self.peekId = peekId
    }
    func encrypt(peerId: String, plaintext: Data) throws -> Data { Data([typeByte]) + plaintext }
    func decrypt(peerId: String, payload: Data) throws -> Data { payload.dropFirst() }
    func peekSenderId(fromKindPayload payload: Data) -> String? { peekId }
}

final class MessagePipelineTests: XCTestCase {

    func testSealThenOpenRoundTrip() throws {
        let crypto = MockEngine()
        let payload = try TextMessage(b: "やあ", n: "Me", ts: 1, mid: "m1").toPayloadJSON()

        let env = try OutgoingSealer.seal(payload: payload, replyBox: "RBOX", to: "PEER", crypto: crypto)
        XCTAssertEqual(env.count, Wire.size)          // fixed 4096B envelope
        XCTAssertEqual([UInt8](env)[0], 2)            // version
        XCTAssertEqual([UInt8](env)[1], UInt8(Wire.kindSignal))

        let opened = try IncomingOpener.open(envelope: env, knownSender: "PEER", crypto: crypto)
        XCTAssertEqual(opened.senderId, "PEER")
        XCTAssertEqual(opened.type, .text)
        XCTAssertEqual(opened.replyBox, "RBOX")       // rb stamped on the way out, read on the way in
        let back = try JSONDecoder().decode(TextMessage.self, from: opened.payload)
        XCTAssertEqual(back.b, "やあ")
        XCTAssertEqual(back.mid, "m1")
    }

    func testStampsReplyBoxEvenWhenAbsent() throws {
        let crypto = MockEngine()
        let payload = #"{"t":"read","ids":["a","b"]}"#.data(using: .utf8)!
        let env = try OutgoingSealer.seal(payload: payload, replyBox: "MYBOX", to: "P", crypto: crypto)
        let opened = try IncomingOpener.open(envelope: env, knownSender: "P", crypto: crypto)
        XCTAssertEqual(opened.replyBox, "MYBOX")
        XCTAssertEqual(opened.type, .read)
    }

    func testOpenRecoversSenderViaPeek() throws {
        let crypto = MockEngine(peekId: "FRESH-PEER")
        let env = try OutgoingSealer.seal(payload: #"{"t":"text","b":"hi"}"#.data(using: .utf8)!,
                                          replyBox: "B", to: "X", crypto: crypto)
        let opened = try IncomingOpener.open(envelope: env, knownSender: nil, crypto: crypto)
        XCTAssertEqual(opened.senderId, "FRESH-PEER")
    }

    func testOpenThrowsWhenSenderUnresolvable() throws {
        let crypto = MockEngine(peekId: nil)
        let env = try OutgoingSealer.seal(payload: #"{"t":"text","b":"hi"}"#.data(using: .utf8)!,
                                          replyBox: "B", to: "X", crypto: crypto)
        XCTAssertThrowsError(try IncomingOpener.open(envelope: env, knownSender: nil, crypto: crypto)) {
            XCTAssertEqual($0 as? PipelineError, .unknownSender)
        }
    }
}
