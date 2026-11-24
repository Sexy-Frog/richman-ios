import Foundation

/// The media descriptor carried as a JSON **string** in `group_msg.m` (kind
/// "img"/"file") and stored as a group media row's body. It is a bare object
/// with NO `"t"` discriminator — distinct from the 1:1 `ImageMessage` /
/// `FileMessage`, which carry `t` and travel as top-level payloads.
///
/// Matches Android `ChatController.doSendGroupMedia` manifests exactly:
///   img  → `{"id","k","n","mime","sz"}`
///   file → `{"id","k","n","name","mime","sz"}`
/// The ciphertext lives in a one-shot relay blob (`id`); `k`/`n` are the
/// AES-256-GCM key/nonce (base64url) to decrypt it.
public struct MediaManifest: Codable, Equatable {
    public var id: String        // relay blob id
    public var k: String         // AES-256-GCM key (b64url)
    public var n: String         // nonce (b64url)
    public var name: String?     // original file name (file only; omitted for img)
    public var mime: String
    public var sz: Int64

    public init(id: String, k: String, n: String, name: String? = nil, mime: String, sz: Int64) {
        self.id = id; self.k = k; self.n = n; self.name = name; self.mime = mime; self.sz = sz
    }

    /// Encode to the compact JSON string that goes into `group_msg.m`.
    public func manifestString() throws -> String {
        String(decoding: try self.toPayloadJSON(), as: UTF8.self)
    }

    /// Parse a `group_msg.m` string back into a manifest.
    public static func parse(_ s: String) throws -> MediaManifest {
        try JSONDecoder().decode(MediaManifest.self, from: Data(s.utf8))
    }
}
