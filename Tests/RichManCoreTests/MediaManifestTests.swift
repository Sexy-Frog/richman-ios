import XCTest
@testable import RichManCore

/// `group_msg.m` manifest must be byte-shape identical to Android's
/// doSendGroupMedia manifests (img: id/k/n/mime/sz; file: + name).
final class MediaManifestTests: XCTestCase {

    func testImageManifestOmitsName() throws {
        let m = MediaManifest(id: "blob1", k: "KK", n: "NN", mime: "image/jpeg", sz: 2048)
        let obj = try JSONSerialization.jsonObject(with: m.toPayloadJSON()) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "blob1")
        XCTAssertEqual(obj["k"] as? String, "KK")
        XCTAssertEqual(obj["n"] as? String, "NN")
        XCTAssertEqual(obj["mime"] as? String, "image/jpeg")
        XCTAssertEqual(obj["sz"] as? Int, 2048)
        XCTAssertNil(obj["name"])   // img manifest has no name
        XCTAssertNil(obj["t"])      // bare object, no discriminator
    }

    func testFileManifestKeepsName() throws {
        let m = MediaManifest(id: "b2", k: "K", n: "N", name: "doc.pdf", mime: "application/pdf", sz: 99)
        let obj = try JSONSerialization.jsonObject(with: m.toPayloadJSON()) as! [String: Any]
        XCTAssertEqual(obj["name"] as? String, "doc.pdf")
        XCTAssertEqual(obj["mime"] as? String, "application/pdf")
    }

    func testParsesAndroidManifestString() throws {
        let s = #"{"id":"blobX","k":"keyB64","n":"nonceB64","mime":"image/jpeg","sz":12345}"#
        let m = try MediaManifest.parse(s)
        XCTAssertEqual(m.id, "blobX")
        XCTAssertEqual(m.sz, 12345)
        XCTAssertNil(m.name)
    }

    func testRoundTripViaManifestString() throws {
        let m = MediaManifest(id: "i", k: "k", n: "n", name: "f.bin", mime: "application/octet-stream", sz: 7)
        XCTAssertEqual(try MediaManifest.parse(try m.manifestString()), m)
    }
}
