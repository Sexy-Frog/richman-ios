import XCTest
@testable import RichManCore

/// Interop guards for friend-add: the iOS QR / sealed-invite / prekey-bundle
/// JSON must be byte-shape identical to the Android client (createInvite /
/// addFriend / buildBundle), or the two cannot pair over the same relay.
final class InviteTests: XCTestCase {

    func testQRRoundTripAndKeys() throws {
        let qr = QRInvite(id: "ID33", n: "太郎", tag: "TAG16", box: "BOX32", k: "KEY32", t: "tok")
        let data = try qr.toPayloadJSON()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["id"] as? String, "ID33")
        XCTAssertEqual(obj["n"] as? String, "太郎")
        XCTAssertEqual(obj["tag"] as? String, "TAG16")
        XCTAssertEqual(obj["box"] as? String, "BOX32")
        XCTAssertEqual(obj["k"] as? String, "KEY32")
        XCTAssertEqual(obj["t"] as? String, "tok")
        XCTAssertEqual(try JSONDecoder().decode(QRInvite.self, from: data), qr)
    }

    func testParsesAndroidQRString() throws {
        // Exactly what Android createInvite() emits (keys v,id,n,tag,box,k,t).
        let s = #"{"v":1,"id":"abc","n":"Alice","tag":"dHQ","box":"Ym94","k":"aw","t":"T1"}"#
        let qr = try QRInvite.parse(s)
        XCTAssertEqual(qr.id, "abc")
        XCTAssertEqual(qr.k, "aw")
        XCTAssertEqual(qr.t, "T1")
    }

    func testParseRejectsWrongVersion() {
        let s = #"{"v":2,"id":"x","n":"n","tag":"t","box":"b","k":"k","t":"tok"}"#
        XCTAssertThrowsError(try QRInvite.parse(s)) { e in
            XCTAssertEqual(e as? InviteError, .unsupportedVersion)
        }
    }

    func testParseRejectsMalformed() {
        XCTAssertThrowsError(try QRInvite.parse("not json")) { e in
            XCTAssertEqual(e as? InviteError, .malformed)
        }
    }

    func testCheckNotSelf() {
        let qr = QRInvite(id: "me", n: "n", tag: "t", box: "b", k: "k", t: "tok")
        XCTAssertThrowsError(try qr.checkNotSelf(localId: "me")) { e in
            XCTAssertEqual(e as? InviteError, .selfAdd)
        }
        XCTAssertNoThrow(try qr.checkNotSelf(localId: "other"))
    }

    func testSealedInviteKey() throws {
        let sealed = SealedInvite(e: "bm9uY2UrY2lwaGVy")
        let obj = try JSONSerialization.jsonObject(with: sealed.toPayloadJSON()) as! [String: Any]
        XCTAssertEqual(obj.count, 1)
        XCTAssertEqual(obj["e"] as? String, "bm9uY2UrY2lwaGVy")
        XCTAssertEqual(try JSONDecoder().decode(SealedInvite.self, from: sealed.toPayloadJSON()), sealed)
    }

    func testBundleRoundTripAndNestedKeys() throws {
        let b = PrekeyBundle(
            id: "abc", n: "Alice", tag: "dHQ", box: "Ym94", reg: 1234,
            spk: SignedPreKeyPublic(i: 7, p: "spkP", s: "spkS"),
            opk: OneTimePreKeyPublic(i: 9, p: "opkP"),
            kpk: KyberPreKeyPublic(i: 3, p: "kpkP", s: "kpkS")
        )
        let data = try b.toPayloadJSON()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["reg"] as? Int, 1234)

        let spk = obj["spk"] as! [String: Any]
        XCTAssertEqual(spk["i"] as? Int, 7)
        XCTAssertEqual(spk["p"] as? String, "spkP")
        XCTAssertEqual(spk["s"] as? String, "spkS")

        let opk = obj["opk"] as! [String: Any]
        XCTAssertEqual(opk["i"] as? Int, 9)
        XCTAssertEqual(opk["p"] as? String, "opkP")
        XCTAssertNil(opk["s"])   // one-time prekey is unsigned

        let kpk = obj["kpk"] as! [String: Any]
        XCTAssertEqual(kpk["i"] as? Int, 3)
        XCTAssertEqual(kpk["s"] as? String, "kpkS")

        XCTAssertEqual(try PrekeyBundle.decode(data), b)
    }

    func testBundleDecodesWithoutOpk() throws {
        // Android reads opk with optJSONObject — a bundle lacking it must still decode.
        let json = #"{"v":1,"id":"abc","n":"A","tag":"t","box":"b","reg":1,"spk":{"i":1,"p":"P","s":"S"},"kpk":{"i":2,"p":"KP","s":"KS"}}"#
        let b = try PrekeyBundle.decode(Data(json.utf8))
        XCTAssertNil(b.opk)
        XCTAssertEqual(b.spk.p, "P")
        XCTAssertEqual(b.kpk.s, "KS")
    }

    func testValidateAgainstQR() throws {
        let qr = QRInvite(id: "abc", n: "A", tag: "dHQ", box: "Ym94", k: "k", t: "tok")
        func bundle(id: String = "abc", tag: String = "dHQ", box: String = "Ym94") -> PrekeyBundle {
            PrekeyBundle(id: id, n: "A", tag: tag, box: box, reg: 1,
                         spk: SignedPreKeyPublic(i: 1, p: "p", s: "s"),
                         opk: OneTimePreKeyPublic(i: 2, p: "p"),
                         kpk: KyberPreKeyPublic(i: 3, p: "p", s: "s"))
        }
        XCTAssertNoThrow(try bundle().validate(against: qr))
        XCTAssertThrowsError(try bundle(id: "other").validate(against: qr)) {
            XCTAssertEqual($0 as? InviteError, .mismatchedIdentity)
        }
        XCTAssertThrowsError(try bundle(tag: "bad").validate(against: qr)) {
            XCTAssertEqual($0 as? InviteError, .mismatchedRouting)
        }
        XCTAssertThrowsError(try bundle(box: "bad").validate(against: qr)) {
            XCTAssertEqual($0 as? InviteError, .mismatchedMailbox)
        }
    }
}
