import XCTest
import RichManCore
@testable import RichManCrypto

/// Each invite must address a fresh 32-byte mailbox so the relay cannot link
/// two contacts through a shared routing value (Android 1.0.21 behaviour).
final class InviteBundleBoxTests: XCTestCase {
    func testBundleCarriesTheSuppliedBox() throws {
        let keys = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        let box = Data((0..<32).map { UInt8($0) })
        let json = try JSONSerialization.jsonObject(
            with: try keys.buildBundle(displayName: "A", box: box)
        ) as! [String: Any]
        XCTAssertEqual(json["box"] as? String, Base64URL.encode(box))
        XCTAssertEqual(json["id"] as? String, keys.id)
    }

    func testTwoInvitesUseDifferentBoxes() throws {
        let keys = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        let first = try JSONSerialization.jsonObject(
            with: try keys.buildBundle(displayName: "A", box: Data(repeating: 1, count: 32))
        ) as! [String: Any]
        let second = try JSONSerialization.jsonObject(
            with: try keys.buildBundle(displayName: "A", box: Data(repeating: 2, count: 32))
        ) as! [String: Any]
        XCTAssertNotEqual(first["box"] as? String, second["box"] as? String)
        XCTAssertEqual(first["id"] as? String, second["id"] as? String)
    }

    func testWrongBoxLengthThrows() throws {
        let keys = try KeyManager(backend: InMemoryKeyStore.createIdentity())
        XCTAssertThrowsError(
            try keys.buildBundle(displayName: "A", box: Data(repeating: 0, count: 16))
        )
    }
}
