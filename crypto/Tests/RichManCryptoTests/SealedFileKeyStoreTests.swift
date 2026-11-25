import XCTest
import CryptoKit
@testable import RichManCrypto

final class SealedFileKeyStoreTests: XCTestCase {
    func testIdentityPersistsAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("richman-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = SymmetricKey(size: .bits256)

        let first = try KeyManager(backend: try SealedFileKeyStore(url: url, key: key))
        let id = first.id
        _ = try first.buildBundle(displayName: "Alice")

        let second = try KeyManager(backend: try SealedFileKeyStore(url: url, key: key))
        XCTAssertEqual(second.id, id)
        XCTAssertFalse(second.hasSession(peerId: "nobody"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSealedFileIsNotPlainJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("richman-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = SymmetricKey(size: .bits256)
        _ = try SealedFileKeyStore(url: url, key: key)

        let raw = try Data(contentsOf: url)
        XCTAssertGreaterThan(raw.count, 1)
        XCTAssertNotEqual(raw.first, UInt8(ascii: "{"))
    }
}
