import Foundation

/// The decrypted libsignal payload is JSON with a `"t"` discriminator. These
/// Codable models mirror the CURRENT Android client's shapes exactly (see the
/// Android `chat/ChatController.kt` send/receive paths — the source of truth for
/// interop; `docs/PROTOCOL.md` is the written spec). The reply mailbox `rb`
/// is stamped onto every outgoing payload by the transport layer (see
/// `MessagePayload`), never carried in the envelope.
public enum MessageType: String, Codable {
    case text
    case read
    case ttl
    case img
    case file
    case del
    case profile
    case loc
    case locOnce = "loc_once"
    case locReq = "loc_req"
    case locDenied = "loc_denied"
    case locStart = "loc_start"
    case locUpdate = "loc_update"
    case locStop = "loc_stop"
    case groupInvite = "group_invite"
    case groupMsg = "group_msg"
    case groupAdd = "group_add"
    case groupLeave = "group_leave"
    case groupRemove = "group_remove"
    case groupDel = "group_del"
    case callOffer = "call_offer"
    case callAnswer = "call_answer"
    case callEnd = "call_end"
    case callAudio = "call_audio"
}

/// Dispatch / reply-mailbox helpers that read raw payload JSON without a full decode.
public enum MessagePayload {

    /// The `"t"` discriminator, or nil if absent/unknown.
    public static func type(of json: Data) -> MessageType? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        return MessageType(rawValue: t)
    }

    /// The sender's reply mailbox (`rb`, base64url of 32 bytes), or nil if absent.
    public static func replyBox(of json: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return obj["rb"] as? String
    }

    /// Stamp the sender's reply mailbox into a payload before sealing — mirrors
    /// the Android `transmit()` which adds `rb` to the JSON just before encrypt.
    public static func stampReplyBox(_ json: Data, rb: String) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return json }
        obj["rb"] = rb
        return (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? json
    }
}

/// Back-compat alias (older code referenced `MessageHeader.type`).
public typealias MessageHeader = MessagePayload

public struct GroupMember: Codable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

// MARK: 1:1 content

public struct TextMessage: Codable, Equatable {
    public var t = MessageType.text.rawValue
    public var b: String           // body
    public var n: String?          // sender display name
    public var ts: Int64?
    public var mid: String?        // message id (for receipts / delete / reply)
    public var exp: Int64?         // disappearing expiry (absolute ms)
    public var re: String?         // replied-to mid
    public var ren: String?        // replied-to name
    public var ret: String?        // replied-to text snippet
    public init(b: String, n: String? = nil, ts: Int64? = nil, mid: String? = nil,
                exp: Int64? = nil, re: String? = nil, ren: String? = nil, ret: String? = nil) {
        self.b = b; self.n = n; self.ts = ts; self.mid = mid
        self.exp = exp; self.re = re; self.ren = ren; self.ret = ret
    }
}

public struct ImageMessage: Codable, Equatable {
    public var t = MessageType.img.rawValue
    public var id: String          // blob id
    public var k: String           // AES-256-GCM key (b64url)
    public var n: String           // nonce (b64url)
    public var mime: String
    public var sz: Int64
    public var mid: String?
    public var exp: Int64?

    public init(id: String, k: String, n: String, mime: String, sz: Int64,
                mid: String? = nil, exp: Int64? = nil) {
        self.id = id; self.k = k; self.n = n; self.mime = mime; self.sz = sz
        self.mid = mid; self.exp = exp
    }
}

public struct FileMessage: Codable, Equatable {
    public var t = MessageType.file.rawValue
    public var id: String
    public var k: String
    public var n: String
    public var name: String
    public var mime: String
    public var sz: Int64
    public var mid: String?
    public var exp: Int64?

    public init(id: String, k: String, n: String, name: String, mime: String,
                sz: Int64, mid: String? = nil, exp: Int64? = nil) {
        self.id = id; self.k = k; self.n = n; self.name = name; self.mime = mime
        self.sz = sz; self.mid = mid; self.exp = exp
    }
}

/// `{"t":"read","ids":[...]}` — read receipt for the peer's inbound mids.
public struct ReadReceipt: Codable, Equatable {
    public var t = MessageType.read.rawValue
    public var ids: [String]
    public init(ids: [String]) { self.ids = ids }
}

/// `{"t":"ttl","ms":N}` — set the 1:1 disappearing timer (0 = off).
public struct TtlMessage: Codable, Equatable {
    public var t = MessageType.ttl.rawValue
    public var ms: Int64
    public init(ms: Int64) { self.ms = ms }
}

/// `{"t":"del","ids":[...]}` — delete-for-everyone, by mid, within this 1:1 chat.
public struct DeleteMessage: Codable, Equatable {
    public var t = MessageType.del.rawValue
    public var ids: [String]
    public init(ids: [String]) { self.ids = ids }
}

/// `{"t":"profile",...}` — name/bio/addMode inline; avatar out-of-band via a blob.
public struct ProfileMessage: Codable, Equatable {
    public var t = MessageType.profile.rawValue
    public var n: String?
    public var bio: String?
    public var addMode: String?
    public var av: Int             // 1 = avatar blob present, 0 = cleared
    public var avBlob: String?
    public var avK: String?
    public var avN: String?
}

// MARK: Location (self-initiated; docs/PROTOCOL.md §8)

/// loc / loc_once / loc_start / loc_update share this shape.
public struct LocationMessage: Codable, Equatable {
    public var t: String
    public var id: String?
    public var lat: Double
    public var lon: Double
    public var acc: Double?
    public var ts: Int64?
    public var end: Int64?         // live-share end time (start/update); 0 = indefinite

    public init(t: String, id: String? = nil, lat: Double, lon: Double,
                acc: Double? = nil, ts: Int64? = nil, end: Int64? = nil) {
        self.t = t; self.id = id; self.lat = lat; self.lon = lon
        self.acc = acc; self.ts = ts; self.end = end
    }
}

public struct LocationStop: Codable, Equatable {
    public var t = MessageType.locStop.rawValue
    public var id: String
    public var why: String?        // user | background | spoof | nopeers | ...
}

/// `{"t":"loc_req","id":"..."}` — a (non-coercive) request for the peer's location.
public struct LocationRequest: Codable, Equatable {
    public var t = MessageType.locReq.rawValue
    public var id: String
    public init(id: String) { self.id = id }
}

/// `{"t":"loc_denied","why":"..."}` — peer is not sharing / unavailable.
public struct LocationDenied: Codable, Equatable {
    public var t = MessageType.locDenied.rawValue
    public var why: String?
}

// MARK: Groups (hub model; docs/PROTOCOL.md §7)

public struct GroupInviteMessage: Codable, Equatable {
    public var t = MessageType.groupInvite.rawValue
    public var gid: String
    public var name: String
    public var hub: String
    public var hub_box: String
    public var hub_tag: String
    public var members: [GroupMember]
    public var n: String?
    public var ts: Int64?
}

/// `group_msg` carries text (`b`) or a media manifest string (`m`) per `kind`.
public struct GroupMessage: Codable, Equatable {
    public var t = MessageType.groupMsg.rawValue
    public var gid: String
    public var kind: String        // "text" | "img" | "file"
    public var b: String?          // text body
    public var m: String?          // media manifest JSON (img/file)
    public var n: String           // sender display name
    public var sender: String      // sender id
    public var ts: Int64?
    public var mid: String?
    public var re: String?
    public var ren: String?
    public var ret: String?
    public var mentions: [String]?
}

/// group_add / group_leave / group_remove membership signals (from/forwarded by hub).
public struct GroupMembershipMessage: Codable, Equatable {
    public var t: String
    public var gid: String
    public var id: String?         // affected member (add/remove)
    public var name: String?
    public var n: String?          // actor display name
    public var ts: Int64?
}

/// `{"t":"group_del","gid":"...","ids":[...],"sender":"...","ts":...}`
public struct GroupDeleteMessage: Codable, Equatable {
    public var t = MessageType.groupDel.rawValue
    public var gid: String
    public var ids: [String]
    public var sender: String
    public var ts: Int64?
}

// MARK: Calls (reuse the encrypted message path)

/// call_offer / call_answer / call_end. `sr` negotiates the audio sample rate
/// (16000 wideband; absent/8000 for older peers).
public struct CallSignal: Codable, Equatable {
    public var t: String
    public var id: String
    public var n: String?          // display name (offer)
    public var sr: Int?            // negotiated sample rate (offer/answer)
    public var why: String?        // end reason (end)
}

/// `{"t":"call_audio","id":"...","seq":N,"d":"<ADPCM base64>"}`
public struct CallAudio: Codable, Equatable {
    public var t = MessageType.callAudio.rawValue
    public var id: String
    public var peer: String?
    public var seq: Int64
    public var d: String           // ADPCM, base64
}

public extension Encodable {
    /// Encode to compact JSON for the libsignal payload (no slash escaping,
    /// nil optionals omitted — matches the Android org.json output).
    func toPayloadJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try enc.encode(self)
    }
}
