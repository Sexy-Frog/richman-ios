import XCTest
import Foundation
import CryptoKit
@testable import RichManCrypto

/// At-rest sealing: AES-256-GCM, format `[ver=1][nonce12][ct][tag16]`,
/// byte-compatible with the Android `CryptoBox`. Destroying the key must make
/// ciphertext permanently unreadable (the basis for emergency wipe).
final class SealedBoxTests: XCTestCase {

    func testSealOpenRoundTrip() throws {
        let box = SealedBox(key: SymmetricKey(size: .bits256))
        let plain = Data("秘密のメッセージ".utf8)
        let sealed = try box.seal(plain)
        XCTAssertEqual(sealed.first, 1)                 // version byte
        XCTAssertGreaterThan(sealed.count, plain.count) // nonce + tag overhead
        XCTAssertNotEqual(sealed, plain)
        XCTAssertEqual(try box.open(sealed), plain)
    }

    func testWrongKeyFails() throws {
        let sealed = try SealedBox(key: SymmetricKey(size: .bits256)).seal(Data("x".utf8))
        XCTAssertThrowsError(try SealedBox(key: SymmetricKey(size: .bits256)).open(sealed))
    }

    func testTamperedCiphertextFails() throws {
        let box = SealedBox(key: SymmetricKey(size: .bits256))
        var sealed = try box.seal(Data("payload".utf8))
        sealed[sealed.count - 1] ^= 0xFF               // flip a tag bit
        XCTAssertThrowsError(try box.open(sealed))
    }

    func testRejectsShortAndBadVersion() {
        let box = SealedBox(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try box.open(Data([1, 2, 3])))
        var bad = (try? box.seal(Data("y".utf8))) ?? Data()
        if !bad.isEmpty { bad[0] = 9; XCTAssertThrowsError(try box.open(bad)) }
    }
}
