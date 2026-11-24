import Foundation

/// Per-install routing identifiers the relay sees but cannot link to an identity.
/// `box` (32B) is the mailbox; `tag` (16B) is the sender pseudonym. Generated once
/// at install and stored in `meta` (see docs/PROTOCOL.md §1).
public struct LocalIdentifiers: Equatable {
    public let box: Data   // 32 bytes
    public let tag: Data   // 16 bytes

    public init(box: Data, tag: Data) {
        precondition(box.count == 32, "box must be 32 bytes")
        precondition(tag.count == 16, "tag must be 16 bytes")
        self.box = box
        self.tag = tag
    }

    /// Fresh random identifiers for a new install.
    public static func generate() -> LocalIdentifiers {
        LocalIdentifiers(box: secureRandomData(32), tag: secureRandomData(16))
    }
}

public enum Ids {
    /// Contact / group-message primary key: base64url(identity, 33 bytes).
    public static func id(fromIdentity identity: Data) -> String {
        Base64URL.encode(identity)
    }

    public static func identity(fromId id: String) throws -> Data {
        try Base64URL.decode(id)
    }

    /// Group id: "g:" + base64url(16 random bytes).
    public static func newGroupId() -> String {
        "g:" + Base64URL.encode(secureRandomData(16))
    }

    public static func isGroupId(_ s: String) -> Bool { s.hasPrefix("g:") }
}
