import Foundation

/// URL-safe base64 with no padding — matches the Android `B64` object
/// (`Base64.URL_SAFE | NO_WRAP | NO_PADDING`). Used for `id`, tokens and the
/// relay JSON fields. Standard base64 (`+`/`/`, `=` padding) is NOT interchangeable.
public enum Base64URL {

    public static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    public enum DecodeError: Error { case invalidBase64 }

    public static func decode(_ text: String) throws -> Data {
        var s = text
        s = s.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        // restore padding to a multiple of 4
        let rem = s.count % 4
        if rem == 2 { s += "==" }
        else if rem == 3 { s += "=" }
        else if rem == 1 { throw DecodeError.invalidBase64 }
        guard let data = Data(base64Encoded: s) else { throw DecodeError.invalidBase64 }
        return data
    }
}

public extension Data {
    var b64url: String { Base64URL.encode(self) }
}
