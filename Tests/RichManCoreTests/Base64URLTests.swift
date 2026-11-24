import XCTest
@testable import RichManCore

final class Base64URLTests: XCTestCase {

    func testKnownVectorIsUrlSafeNoPadding() throws {
        // Bytes FB FF FE -> standard base64 "+//+" -> url-safe no-pad "-__-"
        let data = Data([0xFB, 0xFF, 0xFE])
        XCTAssertEqual(Base64URL.encode(data), "-__-")
        XCTAssertEqual(try Base64URL.decode("-__-"), data)
    }

    func testNoPaddingEmitted() {
        XCTAssertFalse(Base64URL.encode(Data([0x00])).contains("="))
        XCTAssertFalse(Base64URL.encode(Data([0x00, 0x01])).contains("="))
        XCTAssertEqual(Base64URL.encode(Data([0x00])), "AA")
    }

    func testRoundTripRandom() throws {
        for len in [0, 1, 2, 3, 16, 32, 33, 100, 255] {
            let d = secureRandomData(len)
            let s = Base64URL.encode(d)
            XCTAssertFalse(s.contains("+"))
            XCTAssertFalse(s.contains("/"))
            XCTAssertFalse(s.contains("="))
            XCTAssertEqual(try Base64URL.decode(s), d)
        }
    }

    func testEmpty() throws {
        XCTAssertEqual(Base64URL.encode(Data()), "")
        XCTAssertEqual(try Base64URL.decode(""), Data())
    }

    func testInvalidThrows() {
        XCTAssertThrowsError(try Base64URL.decode("A"))   // length %4 == 1 is impossible
    }
}
