import XCTest
import Foundation
@testable import RichManCore

final class AdpcmTests: XCTestCase {
    /// A sine sweep at 16 kHz in 300 ms chunks should round-trip with bounded
    /// error and exactly 4 bits per sample.
    func testRoundTripConvertsShapeAndStaysBounded() {
        let rate = 16000
        let count = rate * 300 / 1000
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            pcm[i] = Int16(sin(2 * .pi * 440 * t) * 12000)
        }

        let encoded = Adpcm.encode(pcm)
        XCTAssertEqual(encoded.count, (count + 1) / 2)
        let decoded = Adpcm.decode(encoded)
        XCTAssertEqual(decoded.count, count)

        // ADPCM is lossy but must track a 440 Hz tone closely enough to be
        // intelligible; compare RMS error against signal RMS.
        var signal = 0.0
        var noise = 0.0
        for i in 0..<count {
            let s = Double(pcm[i])
            signal += s * s
            let e = Double(decoded[i]) - s
            noise += e * e
        }
        let snr = 10 * log10(signal / max(noise, 1))
        XCTAssertGreaterThan(snr, 10.0, "SNR too low: \(snr)")
        XCTAssertLessThan(decoded.map { abs(Int($0)) }.max() ?? 0, 33000)
    }

    func testSilenceDecodesNearZero() {
        let pcm = [Int16](repeating: 0, count: 4800)
        let decoded = Adpcm.decode(Adpcm.encode(pcm))
        XCTAssertLessThan(decoded.map { abs(Int($0)) }.max() ?? 0, 64)
    }

    func testNibbleOrderIsLowThenHigh() {
        // A single positive delta produces a non-zero low nibble first; the
        // packed byte must keep it in the low 4 bits (Android layout).
        let encoded = Adpcm.encode([1000, 1000])
        XCTAssertEqual(encoded.count, 1)
        XCTAssertNotEqual(Int(encoded[0]) & 0x0F, 0)
    }

    func testEmptyAndOddLengths() {
        XCTAssertEqual(Adpcm.encode([]).count, 0)
        XCTAssertEqual(Adpcm.decode(Data()).count, 0)
        XCTAssertEqual(Adpcm.encode([1]).count, 1)
        XCTAssertEqual(Adpcm.decode(Data([0x00])).count, 2)
    }
}
