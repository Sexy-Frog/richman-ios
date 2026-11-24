import Foundation
#if canImport(Security)
import Security
#endif

/// Cryptographically secure random bytes. Uses the system CSPRNG
/// (`SecRandomCopyBytes` on Apple platforms), falling back to
/// `SystemRandomNumberGenerator` elsewhere so the package still builds for CI.
public func secureRandomBytes(_ count: Int) -> [UInt8] {
    precondition(count >= 0)
    var bytes = [UInt8](repeating: 0, count: count)
    if count == 0 { return bytes }
    #if canImport(Security)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    if status == errSecSuccess { return bytes }
    #endif
    var rng = SystemRandomNumberGenerator()
    for i in 0..<count { bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
    return bytes
}

/// Secure random `Data` of the given length.
public func secureRandomData(_ count: Int) -> Data {
    Data(secureRandomBytes(count))
}
