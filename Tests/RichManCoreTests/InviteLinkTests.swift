import XCTest
import RichManCore

final class InviteLinkTests: XCTestCase {
    private let invite = "{\"v\":1,\"id\":\"abc\",\"n\":\"テスト\"}"

    func testURLRoundTrip() throws {
        let url = try XCTUnwrap(InviteLink.url(for: invite))
        XCTAssertTrue(
            url.absoluteString.hasPrefix("https://kelvins.works/richman/invite.html#")
        )
        XCTAssertEqual(InviteLink.normalize(url.absoluteString), invite)
    }

    func testAppSchemeRoundTrip() throws {
        let url = try XCTUnwrap(InviteLink.appURL(for: invite))
        XCTAssertEqual(url.scheme, "richman")
        XCTAssertEqual(InviteLink.normalize(url.absoluteString), invite)
    }

    func testRawAndBareToken() {
        XCTAssertEqual(InviteLink.normalize(invite), invite)
        let token = Base64URL.encode(Data(invite.utf8))
        XCTAssertEqual(InviteLink.normalize(token), invite)
        XCTAssertEqual(InviteLink.normalize("  \(token)\n"), invite)
    }

    func testRejectsGarbage() {
        XCTAssertNil(InviteLink.normalize(""))
        XCTAssertNil(InviteLink.normalize("hello"))
        XCTAssertNil(InviteLink.normalize("https://example.com/#not-base64"))
    }
}
