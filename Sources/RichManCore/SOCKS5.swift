import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin)
let rmSocketStream: Int32 = SOCK_STREAM
#elseif canImport(Glibc)
let rmSocketStream: Int32 = Int32(SOCK_STREAM.rawValue)
#endif

/// A SOCKS5 proxy endpoint (the embedded Tor listener in production).
public struct SOCKS5Address: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum SOCKS5Error: Error, Equatable {
    case proxy(String)
    case handshake(String)
    case http(String)
    case tooLarge
}

/// Byte-level SOCKS5 / HTTP framing. Kept separate from the socket loop so the
/// wire format is unit-testable on any platform.
public enum SOCKS5Wire {
    public static let version: UInt8 = 5

    /// `VER NMETHODS METHODS...`. With `useUserPass` we advertise ONLY RFC 1929,
    /// so Tor cannot pick no-auth and skip the per-mailbox circuit isolation
    /// that `IsolateSOCKSAuth` keys off the SOCKS username.
    public static func greeting(useUserPass: Bool) -> Data {
        useUserPass ? Data([5, 1, 2]) : Data([5, 1, 0])
    }

    /// RFC 1929 `VER 1 ULEN UNAME PLEN PASSWD`.
    public static func usernamePassword(_ user: String, _ password: String) -> Data {
        var out = Data([1])
        let u = Array(user.utf8.prefix(255))
        out.append(UInt8(u.count))
        out.append(contentsOf: u)
        let p = Array(password.utf8.prefix(255))
        out.append(UInt8(p.count))
        out.append(contentsOf: p)
        return out
    }

    /// CONNECT request. Uses ATYP=3 (domain) so `.onion` resolution happens
    /// inside Tor, never on the device's resolver.
    public static func connect(host: String, port: UInt16) -> Data {
        var out = Data([5, 1, 0])
        let name = Array(host.utf8.prefix(255))
        out.append(3)
        out.append(UInt8(name.count))
        out.append(contentsOf: name)
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xff))
        return out
    }

    /// Minimal HTTP/1.1 request. We always send `Connection: close` and never
    /// advertise gzip, so the response terminates at EOF / Content-Length.
    public static func httpRequest(
        method: String,
        path: String,
        host: String,
        contentType: String?,
        body: Data?
    ) -> Data {
        var head = "\(method) /\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Accept: */*\r\n"
        head += "Connection: close\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        if let body {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }

    /// Split an HTTP response head + body. Throws on a malformed status line.
    public static func parseHTTP(_ raw: Data) throws -> RelayResponse {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw SOCKS5Error.http("missing header terminator")
        }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let body = Data(raw[split.upperBound...])
        guard let statusLine = head.split(separator: "\r\n").first else {
            throw SOCKS5Error.http("empty response")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw SOCKS5Error.http("bad status line")
        }
        return RelayResponse(status: status, body: body)
    }
}

/// `RelayTransport` that dials the relay through a SOCKS5 proxy, sending the
/// absolute-target CONNECT and the HTTP request over that socket. Every request
/// gets a fresh connection (no pool) so relay-side connection reuse cannot link
/// separate mailboxes.
public final class SOCKS5Transport: RelayTransport, @unchecked Sendable {
    private let proxy: SOCKS5Address
    private let targetHost: String
    private let targetPort: UInt16
    private let username: String?
    private let password: String
    private let timeout: TimeInterval
    private let maxResponse: Int

    public init(
        proxy: SOCKS5Address,
        targetHost: String,
        targetPort: UInt16 = 80,
        username: String? = nil,
        password: String = "x",
        timeout: TimeInterval = 120,
        maxResponse: Int = 16 * 1024 * 1024
    ) {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.username = username
        self.password = password
        self.timeout = timeout
        self.maxResponse = maxResponse
    }

    public func perform(
        method: String,
        path: String,
        contentType: String?,
        body: Data?
    ) async throws -> RelayResponse {
        let proxy = self.proxy
        let targetHost = self.targetHost
        let targetPort = self.targetPort
        let username = self.username
        let password = self.password
        let timeout = self.timeout
        let maxResponse = self.maxResponse
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let response = try SOCKS5Transport.run(
                        proxy: proxy,
                        targetHost: targetHost,
                        targetPort: targetPort,
                        username: username,
                        password: password,
                        timeout: timeout,
                        maxResponse: maxResponse,
                        method: method,
                        path: path,
                        contentType: contentType,
                        body: body
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: socket loop

    private static func run(
        proxy: SOCKS5Address,
        targetHost: String,
        targetPort: UInt16,
        username: String?,
        password: String,
        timeout: TimeInterval,
        maxResponse: Int,
        method: String,
        path: String,
        contentType: String?,
        body: Data?
    ) throws -> RelayResponse {
        let fd = try dial(proxy, timeout: timeout)
        defer { close(fd) }

        // 1. method negotiation
        try sendAll(fd, SOCKS5Wire.greeting(useUserPass: username != nil))
        let choice = try recvExactly(fd, 2)
        guard choice[0] == 5 else { throw SOCKS5Error.handshake("bad version") }
        switch choice[1] {
        case 0:
            break
        case 2:
            guard let username else { throw SOCKS5Error.handshake("auth required") }
            try sendAll(fd, SOCKS5Wire.usernamePassword(username, password))
            let auth = try recvExactly(fd, 2)
            guard auth[0] == 1, auth[1] == 0 else {
                throw SOCKS5Error.handshake("auth rejected")
            }
        case 0xff:
            throw SOCKS5Error.handshake("no acceptable method")
        default:
            throw SOCKS5Error.handshake("unexpected method \(choice[1])")
        }

        // 2. CONNECT to the onion host (domain name resolved by Tor)
        try sendAll(fd, SOCKS5Wire.connect(host: targetHost, port: targetPort))
        let replyHead = try recvExactly(fd, 4)
        guard replyHead[0] == 5 else { throw SOCKS5Error.handshake("bad reply version") }
        guard replyHead[1] == 0 else {
            throw SOCKS5Error.handshake("connect failed (0x\(String(replyHead[1], radix: 16)))")
        }
        switch replyHead[3] {
        case 1:
            _ = try recvExactly(fd, 4)
        case 4:
            _ = try recvExactly(fd, 16)
        case 3:
            let length = try recvExactly(fd, 1)[0]
            _ = try recvExactly(fd, Int(length))
        default:
            throw SOCKS5Error.handshake("bad address type")
        }
        _ = try recvExactly(fd, 2) // bound port

        // 3. HTTP request
        try sendAll(
            fd,
            SOCKS5Wire.httpRequest(
                method: method,
                path: path,
                host: targetHost,
                contentType: contentType,
                body: body
            )
        )

        // 4. response: read headers, then exactly Content-Length bytes (or EOF)
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        var contentLength: Int?
        while true {
            if buffer.count > maxResponse { throw SOCKS5Error.tooLarge }
            if headerEnd == nil, let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = split
                if let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) {
                    for line in head.split(separator: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
            }
            if let split = headerEnd {
                let received = buffer.count - split.upperBound
                if let contentLength, received >= contentLength { break }
            }
            let chunk = try recvSome(fd, limit: 64 * 1024)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return try SOCKS5Wire.parseHTTP(buffer)
    }

    private static func dial(_ proxy: SOCKS5Address, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: rmSocketStream,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(proxy.host, String(proxy.port), &hints, &result)
        guard rc == 0, let first = result else {
            throw SOCKS5Error.proxy("cannot resolve proxy \(proxy.host)")
        }
        defer { freeaddrinfo(result) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(
                    tv_sec: Int(timeout),
                    tv_usec: suseconds_t(0)
                )
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                #if canImport(Darwin)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                #endif
                if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            current = info.pointee.ai_next
        }
        throw SOCKS5Error.proxy("cannot connect to proxy")
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags: Int32 = Int32(MSG_NOSIGNAL)
        #endif
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = send(fd, base.advanced(by: sent), raw.count - sent, flags)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw SOCKS5Error.proxy("send failed (errno \(errno))")
                }
            }
        }
    }

    private static func recvSome(_ fd: Int32, limit: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            let n = recv(fd, &buffer, limit, 0)
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 { return Data() }
            if errno == EINTR { continue }
            throw SOCKS5Error.proxy("recv failed (errno \(errno))")
        }
    }

    private static func recvExactly(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = try recvSome(fd, limit: count - out.count)
            if chunk.isEmpty { throw SOCKS5Error.handshake("unexpected EOF") }
            out.append(contentsOf: chunk)
        }
        return out
    }
}
