import Foundation

/// Friend-add: QR invite + a one-time, sealed prekey bundle. These JSON shapes
/// mirror the CURRENT Android client exactly — `ChatController.createInvite()` /
/// `addFriend()` and `KeyManager.buildBundle()` — so an iOS client pairs with an
/// Android one over the same relay (see `docs/PROTOCOL.md` §2). Android is the
/// interop source of truth.
///
/// Flow:
///  1. Inviter builds a `PrekeyBundle` (identity + signed/kyber/one-time prekeys,
///     plus routing `tag`/`box` and display name).
///  2. It is AES-256-GCM sealed under a fresh 32-byte key `k`: the stored blob is
///     `nonce(12) ‖ ciphertext`, base64url, wrapped as `SealedInvite {e}`.
///  3. The sealed blob goes to `POST /v1/invite` → relay token `t`.
///  4. The inviter shows a `QRInvite {v,id,n,tag,box,k,t}`. `k` travels ONLY in
///     the (in-person, out-of-band) QR, never to the relay — so the relay holds
///     an opaque `{e}` it cannot read.
///  5. The scanner parses the QR, fetches by `t` (relay deletes it), decrypts the
///     bundle with `k`, cross-checks `id`/`tag`/`box` against the QR, then runs
///     X3DH + PQXDH (`startSession`) on the bundle.
///
/// The AES-GCM seal/open and the X3DH itself live in the (Apple-only) crypto
/// layer; this file is the platform-agnostic, JSON-shape + validation core that
/// `swift test` verifies against Android-shaped fixtures.

/// The QR payload (~250 bytes). All values except `v` are base64url / strings.
public struct QRInvite: Codable, Equatable {
    public var v: Int = 1
    public var id: String        // base64url(identity, 33B) — contact primary key
    public var n: String         // inviter display name
    public var tag: String       // base64url(16B sender pseudonym)
    public var box: String       // base64url(32B invite mailbox minted for the scanner)
    public var k: String         // base64url(32B AES-256-GCM key) — out-of-band in the QR only
    public var t: String         // relay invite token (one-shot, ~15 min)

    public init(id: String, n: String, tag: String, box: String, k: String, t: String, v: Int = 1) {
        self.v = v; self.id = id; self.n = n; self.tag = tag; self.box = box; self.k = k; self.t = t
    }
}

/// The opaque object the relay stores for an invite token. `e` =
/// base64url(nonce(12) ‖ AES-256-GCM ciphertext of the `PrekeyBundle` JSON).
/// The relay never sees the plaintext.
public struct SealedInvite: Codable, Equatable {
    public var e: String
    public init(e: String) { self.e = e }
}

/// X3DH + PQXDH prekey material, sealed inside the invite. A fresh one-time
/// prekey (`opk`) is minted per invite, so each friend gets a distinct handshake.
public struct PrekeyBundle: Codable, Equatable {
    public var v: Int = 1
    public var id: String                  // must equal the QR `id`
    public var n: String                   // inviter display name
    public var tag: String                 // must equal the QR `tag`
    public var box: String                 // must equal the QR `box`
    public var reg: Int                    // libsignal registration id (14-bit)
    public var spk: SignedPreKeyPublic
    public var opk: OneTimePreKeyPublic?   // optional: Android reads it with optJSONObject
    public var kpk: KyberPreKeyPublic

    public init(id: String, n: String, tag: String, box: String, reg: Int,
                spk: SignedPreKeyPublic, opk: OneTimePreKeyPublic?, kpk: KyberPreKeyPublic, v: Int = 1) {
        self.v = v; self.id = id; self.n = n; self.tag = tag; self.box = box
        self.reg = reg; self.spk = spk; self.opk = opk; self.kpk = kpk
    }
}

/// `{i,p,s}` — signed prekey: id, base64url public key, base64url XEdDSA signature.
public struct SignedPreKeyPublic: Codable, Equatable {
    public var i: Int
    public var p: String
    public var s: String
    public init(i: Int, p: String, s: String) { self.i = i; self.p = p; self.s = s }
}

/// `{i,p}` — one-time (ephemeral) prekey: id, base64url public key (unsigned).
public struct OneTimePreKeyPublic: Codable, Equatable {
    public var i: Int
    public var p: String
    public init(i: Int, p: String) { self.i = i; self.p = p }
}

/// `{i,p,s}` — Kyber1024 prekey: id, base64url public key, base64url signature.
public struct KyberPreKeyPublic: Codable, Equatable {
    public var i: Int
    public var p: String
    public var s: String
    public init(i: Int, p: String, s: String) { self.i = i; self.p = p; self.s = s }
}

public enum InviteError: Error, Equatable {
    case unsupportedVersion
    case selfAdd
    case mismatchedIdentity
    case mismatchedRouting
    case mismatchedMailbox
    case malformed
}

public extension QRInvite {
    /// Parse + version-check a scanned QR string — mirrors `addFriend`'s
    /// `require(qr.optInt("v",0) == 1)`.
    static func parse(_ qrText: String) throws -> QRInvite {
        let qr: QRInvite
        do {
            qr = try JSONDecoder().decode(QRInvite.self, from: Data(qrText.utf8))
        } catch {
            throw InviteError.malformed
        }
        guard qr.v == 1 else { throw InviteError.unsupportedVersion }
        return qr
    }

    /// Reject adding yourself — `require(peerId != keys.id)`.
    func checkNotSelf(localId: String) throws {
        if id == localId { throw InviteError.selfAdd }
    }
}

public extension PrekeyBundle {
    /// Decode a decrypted bundle JSON (from the sealed invite).
    static func decode(_ json: Data) throws -> PrekeyBundle {
        do { return try JSONDecoder().decode(PrekeyBundle.self, from: json) }
        catch { throw InviteError.malformed }
    }

    /// Cross-check a decrypted bundle against the QR it came with — mirrors the
    /// Android `addFriend` requires: id, tag and box must all match.
    func validate(against qr: QRInvite) throws {
        guard id == qr.id else { throw InviteError.mismatchedIdentity }
        guard tag == qr.tag else { throw InviteError.mismatchedRouting }
        guard box == qr.box else { throw InviteError.mismatchedMailbox }
    }
}
