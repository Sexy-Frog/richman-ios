import Foundation

/// Fixed-size, padded envelope — the only structure the relay ever sees.
///
///   0        version (2)
///   1        kind (1 = libsignal ciphertext, 2 = operator)
///   2..4     payload length, big endian
///   4..      payload (libsignal message), rest random padding
///
/// The sender's routing tag and reply mailbox are deliberately NOT in the
/// envelope: a relay therefore never learns who sent a message, only the
/// destination mailbox it is posted to (sealed-sender-equivalent). The
/// recipient resolves the sender by trying its sessions, and learns the
/// sender's reply mailbox from inside the end-to-end-encrypted payload (`rb`).
///
/// Constant-size envelopes hide the message length from the relay and from
/// traffic analysis of the onion service. Byte-for-byte compatible with the
/// Android `Wire` object (android/.../net/Wire.kt, VERSION = 2).
public enum Wire {

    public static let version = 2
    public static let kindSignal = 1
    public static let kindOperator = 2
    public static let size = 4096
    public static let header = 4
    public static let maxPayload = size - header // 4092

    public struct Envelope: Equatable {
        public let kind: Int
        public let payload: Data

        public init(kind: Int, payload: Data) {
            self.kind = kind
            self.payload = payload
        }
    }

    public enum WireError: Error, Equatable {
        case payloadOutOfRange
        case badEnvelopeSize
        case unsupportedVersion
        case badPayloadLength
    }

    /// Seal a payload into a 4096-byte random-padded envelope.
    public static func seal(kind: Int, payload: Data) throws -> Data {
        guard payload.count >= 1 && payload.count <= maxPayload else {
            throw WireError.payloadOutOfRange
        }
        var out = secureRandomBytes(size)
        out[0] = UInt8(version & 0xFF)
        out[1] = UInt8(kind & 0xFF)
        out[2] = UInt8((payload.count >> 8) & 0xFF)
        out[3] = UInt8(payload.count & 0xFF)
        out.replaceSubrange(header..<(header + payload.count), with: payload)
        return Data(out)
    }

    /// Parse a 4096-byte envelope. Random padding beyond the declared length is ignored.
    public static func open(_ data: Data) throws -> Envelope {
        guard data.count == size else { throw WireError.badEnvelopeSize }
        let bytes = [UInt8](data)
        guard Int(bytes[0]) == version else { throw WireError.unsupportedVersion }
        let kind = Int(bytes[1])
        let len = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard len >= 1 && len <= maxPayload else { throw WireError.badPayloadLength }
        return Envelope(kind: kind, payload: Data(bytes[header..<(header + len)]))
    }
}
