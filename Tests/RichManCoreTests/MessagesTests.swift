import XCTest
@testable import RichManCore

/// Interop guards: the iOS payload models must encode/decode byte-shape
/// identically to the Android client so the two chat over the same relay.
final class MessagesTests: XCTestCase {

    func testTextRoundTripAndKeys() throws {
        let msg = TextMessage(b: "こんにちは", n: "Alice", ts: 1_690_000_000_000, mid: "m1")
        let data = try msg.toPayloadJSON()
        XCTAssertEqual(MessagePayload.type(of: data), .text)

        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "text")
        XCTAssertEqual(obj["b"] as? String, "こんにちは")
        XCTAssertEqual(obj["mid"] as? String, "m1")
        XCTAssertNil(obj["exp"])   // nil optionals are omitted (matches org.json)

        let back = try JSONDecoder().decode(TextMessage.self, from: data)
        XCTAssertEqual(back, msg)
    }

    func testDecodesAndroidTextWithReplyBox() throws {
        // A payload as the Android client would produce it (extra "rb" key).
        let json = #"{"t":"text","b":"hi","n":"A","ts":1,"mid":"x","rb":"UkJPWA"}"#.data(using: .utf8)!
        XCTAssertEqual(MessagePayload.type(of: json), .text)
        XCTAssertEqual(MessagePayload.replyBox(of: json), "UkJPWA")
        let t = try JSONDecoder().decode(TextMessage.self, from: json)  // unknown "rb" ignored
        XCTAssertEqual(t.b, "hi")
        XCTAssertEqual(t.mid, "x")
    }

    func testStampAndReadReplyBox() {
        let json = #"{"t":"text","b":"hi"}"#.data(using: .utf8)!
        XCTAssertNil(MessagePayload.replyBox(of: json))
        let stamped = MessagePayload.stampReplyBox(json, rb: "BOX")
        XCTAssertEqual(MessagePayload.replyBox(of: stamped), "BOX")
        XCTAssertEqual(MessagePayload.type(of: stamped), .text)
    }

    func testGroupInviteKeys() throws {
        let inv = GroupInviteMessage(
            gid: "g:abc", name: "G", hub: "H", hub_box: "B", hub_tag: "T",
            members: [GroupMember(id: "i", name: "n")], n: "A", ts: 5
        )
        let data = try inv.toPayloadJSON()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "group_invite")
        XCTAssertEqual(obj["hub_box"] as? String, "B")  // snake_case key preserved
        let back = try JSONDecoder().decode(GroupInviteMessage.self, from: data)
        XCTAssertEqual(back, inv)
    }

    func testCallSampleRateNegotiationKey() throws {
        let offer = CallSignal(t: MessageType.callOffer.rawValue, id: "c1", n: "A", sr: 16000, why: nil)
        let obj = try JSONSerialization.jsonObject(with: offer.toPayloadJSON()) as! [String: Any]
        XCTAssertEqual(obj["t"] as? String, "call_offer")
        XCTAssertEqual(obj["sr"] as? Int, 16000)
        XCTAssertNil(obj["why"])
    }
}
