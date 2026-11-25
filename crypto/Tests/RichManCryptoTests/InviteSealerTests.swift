import XCTest
@testable import RichManCrypto

final class InviteSealerTests: XCTestCase {
    func testRoundTrip() throws {
        let key = InviteSealer.newKey()
        XCTAssertEqual(key.count, 32)
        let plain = Data(#"{"v":1,"id":"abc"}"#.utf8)
        let sealed = try InviteSealer.seal(plain, key: key)
        XCTAssertEqual(sealed.count, 12 + plain.count + 16)
        XCTAssertEqual(try InviteSealer.open(sealed, key: key), plain)
    }

    func testWrongKeyFails() throws {
        let sealed = try InviteSealer.seal(Data("secret".utf8), key: InviteSealer.newKey())
        XCTAssertThrowsError(try InviteSealer.open(sealed, key: InviteSealer.newKey()))
    }

    func testTamperFails() throws {
        let key = InviteSealer.newKey()
        var sealed = try InviteSealer.seal(Data("secret".utf8), key: key)
        sealed[sealed.count - 1] ^= 0xff
        XCTAssertThrowsError(try InviteSealer.open(sealed, key: key))
    }

    func testKeyAndLengthValidation() throws {
        XCTAssertThrowsError(try InviteSealer.seal(Data(), key: Data(repeating: 1, count: 31)))
        XCTAssertThrowsError(try InviteSealer.open(Data(), key: InviteSealer.newKey()))
    }
}
