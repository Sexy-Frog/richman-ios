import Foundation

/// IMA ADPCM (4-bit) for mono voice, byte-compatible with the Android client's
/// `call/Adpcm.kt`. Each 300 ms chunk is encoded independently (state reset per
/// chunk), so losing a packet cannot desynchronise later audio.
public enum Adpcm {
    private static let indexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
        16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    public static func encode(_ pcm: [Int16]) -> Data {
        guard !pcm.isEmpty else { return Data() }
        var value: Int = 0
        var index = 0
        var out = Data(capacity: (pcm.count + 1) / 2)

        func encodeSample(_ sample: Int) -> Int {
            let step = stepTable[index]
            var diff = sample - value
            var sign = 0
            if diff < 0 {
                sign = 8
                diff = -diff
            }
            var delta = 0
            var predicted = step >> 3
            if diff >= step {
                delta |= 4
                diff -= step
                predicted += step
            }
            if diff >= (step >> 1) {
                delta |= 2
                diff -= step >> 1
                predicted += step >> 1
            }
            if diff >= (step >> 2) {
                delta |= 1
                predicted += step >> 2
            }
            if sign != 0 { value -= predicted } else { value += predicted }
            value = min(32767, max(-32768, value))
            index = min(88, max(0, index + indexTable[delta]))
            return (sign | delta) & 0x0F
        }

        var i = 0
        while i < pcm.count {
            let lo = encodeSample(Int(pcm[i]))
            let hi = i + 1 < pcm.count ? encodeSample(Int(pcm[i + 1])) : 0
            out.append(UInt8((hi << 4) | (lo & 0x0F)))
            i += 2
        }
        return out
    }

    public static func decode(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }
        var value: Int = 0
        var index = 0
        var out = [Int16](repeating: 0, count: data.count * 2)

        func decodeSample(_ nibble: Int) -> Int16 {
            let step = stepTable[index]
            var predicted = step >> 3
            if nibble & 4 != 0 { predicted += step }
            if nibble & 2 != 0 { predicted += step >> 1 }
            if nibble & 1 != 0 { predicted += step >> 2 }
            if nibble & 8 != 0 { value -= predicted } else { value += predicted }
            value = min(32767, max(-32768, value))
            index = min(88, max(0, index + indexTable[nibble]))
            return Int16(value)
        }

        var i = 0
        for byte in data {
            let b = Int(byte)
            out[i * 2] = decodeSample(b & 0x0F)
            out[i * 2 + 1] = decodeSample((b >> 4) & 0x0F)
            i += 1
        }
        return out
    }
}
