import Foundation
import LibSignalClient

/// libsignal store methods take a `context: StoreContext` (an empty marker
/// protocol). Our stores are plain in-process state, so a single shared
/// null context is enough.
public final class NullContext: StoreContext {
    public static let shared = NullContext()
    public init() {}
}

public enum CryptoError: Error {
    case identityNotInitialised
    case missingKey(String)
    case badBundle(String)
    case identityMismatch
    case emptyCiphertext
    case unsupportedMessageType(UInt8)
}
