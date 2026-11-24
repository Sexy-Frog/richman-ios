import XCTest
@testable import RichManCore

final class WireTests: XCTestCase {

    func testRoundTrip() throws {
        let payload = secureRandomData(1800)

        let sealed = try Wire.seal(kind: Wire.kindSignal, payload: payload)
        XCTAssertEqual(sealed.count, Wire.size)

        let opened = try Wire.open(sealed)
        XCTAssertEqual(opened.kind, Wire.kindSignal)
        XCTAssertEqual(opened.payload, payload)
    }

    func testPaddingIsRandomAndLengthHidden() throws {
        let small = try Wire.seal(kind: 1, payload: Data(repeating: 1, count: 10))
        let large = try Wire.seal(kind: 1, payload: Data(repeating: 2, count: 3000))
        XCTAssertEqual(small.count, Wire.size)
        XCTAssertEqual(large.count, Wire.size)
        XCTAssertNotEqual(small, large)

        let b = [UInt8](small)
        let len = (Int(b[2]) << 8) | Int(b[3])
        XCTAssertEqual(len, 10)
    }

    func testMaxPayloadBoundary() throws {
        XCTAssertEqual(Wire.maxPayload, 4092)
        let maxOk = try Wire.seal(kind: 1, payload: Data(repeating: 7, count: Wire.maxPayload))
        XCTAssertEqual(try Wire.open(maxOk).payload.count, Wire.maxPayload)

        XCTAssertThrowsError(try Wire.seal(kind: 1, payload: Data(repeating: 7, count: Wire.maxPayload + 1)))
        XCTAssertThrowsError(try Wire.seal(kind: 1, payload: Data()))
    }

    func testRejectsBadSizes() {
        XCTAssertThrowsError(try Wire.open(Data(count: 10)))
        XCTAssertThrowsError(try Wire.open(Data(count: Wire.size)))   // version byte 0 != 2
    }

    func testVersionAndKindBytes() throws {
        let sealed = try Wire.seal(kind: Wire.kindOperator, payload: Data([9]))
        let b = [UInt8](sealed)
        XCTAssertEqual(Int(b[0]), Wire.version)       // 2
        XCTAssertEqual(Int(b[1]), Wire.kindOperator)  // 2
    }
}
