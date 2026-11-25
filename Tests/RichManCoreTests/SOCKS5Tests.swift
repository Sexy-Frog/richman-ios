import XCTest
@testable import RichManCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SOCKS5Tests: XCTestCase {

    func testGreetingAndCredentials() {
        XCTAssertEqual(Array(SOCKS5Wire.greeting(useUserPass: false)), [5, 1, 0])
        XCTAssertEqual(Array(SOCKS5Wire.greeting(useUserPass: true)), [5, 1, 2])
        XCTAssertEqual(
            Array(SOCKS5Wire.usernamePassword("box", "x")),
            [1, 3, 0x62, 0x6f, 0x78, 1, 0x78]
        )
    }

    func testConnectUsesDomainName() {
        let bytes = Array(SOCKS5Wire.connect(host: "abc.onion", port: 80))
        XCTAssertEqual(Array(bytes.prefix(5)), [5, 1, 0, 3, 9])
        XCTAssertEqual(Array(bytes[5..<14]), Array("abc.onion".utf8))
        XCTAssertEqual(Array(bytes.suffix(2)), [0, 80])
    }

    func testHTTPRequestShape() {
        let req = SOCKS5Wire.httpRequest(
            method: "POST",
            path: "v1/fetch",
            host: "abc.onion",
            contentType: "application/json",
            body: Data("{}".utf8)
        )
        let text = String(decoding: req, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("POST /v1/fetch HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: abc.onion\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }

    func testParseHTTPWithContentLength() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let response = try SOCKS5Wire.parseHTTP(raw)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello")
    }

    func testParseHTTPRejectsGarbage() {
        XCTAssertThrowsError(try SOCKS5Wire.parseHTTP(Data("nope".utf8)))
    }

    /// End-to-end over a real loopback socket: fake SOCKS5 proxy + fake relay.
    func testTransportRoundTrip() async throws {
        let server = try FakeSOCKS5Relay(
            status: "HTTP/1.1 201 Created",
            body: Data(#"{"token":"t1"}"#.utf8)
        )
        server.start()
        defer { server.stop() }

        let transport = SOCKS5Transport(
            proxy: SOCKS5Address(host: "127.0.0.1", port: server.port),
            targetHost: "example.onion",
            targetPort: 80,
            timeout: 5
        )
        let response = try await transport.perform(
            method: "POST",
            path: "v1/invite",
            contentType: "application/octet-stream",
            body: Data([1, 2, 3])
        )
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"token":"t1"}"#)
        XCTAssertEqual(server.seenHost, "example.onion")
        XCTAssertEqual(server.seenPath, "/v1/invite")
        XCTAssertEqual(server.seenBody, Data([1, 2, 3]))
    }

    func testTransportFailsWithoutProxy() async {
        let transport = SOCKS5Transport(
            proxy: SOCKS5Address(host: "127.0.0.1", port: 1),
            targetHost: "example.onion",
            timeout: 2
        )
        do {
            _ = try await transport.perform(method: "GET", path: "healthz", contentType: nil, body: nil)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error is SOCKS5Error)
        }
    }
}

/// One-shot loopback SOCKS5 server that answers CONNECT and then a fixed HTTP
/// response. Deliberately minimal; only what the transport exercises.
private final class FakeSOCKS5Relay {
    let port: UInt16
    private let listenFD: Int32
    private var thread: Thread?
    private let response: Data
    private let lock = NSLock()
    private var _seenHost: String?
    private var _seenPath: String?
    private var _seenBody: Data?

    var seenHost: String? { lock.lock(); defer { lock.unlock() }; return _seenHost }
    var seenPath: String? { lock.lock(); defer { lock.unlock() }; return _seenPath }
    var seenBody: Data? { lock.lock(); defer { lock.unlock() }; return _seenBody }

    init(status: String, body: Data) throws {
        let fd = socket(AF_INET, rmSocketStream, 0)
        guard fd >= 0 else { throw SOCKS5Error.proxy("socket") }
        listenFD = fd

        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw SOCKS5Error.proxy("bind/listen")
        }

        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw SOCKS5Error.proxy("getsockname")
        }
        port = UInt16(bigEndian: name.sin_port)

        let head = "\(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var raw = Data(head.utf8)
        raw.append(body)
        response = raw
    }

    func start() {
        let thread = Thread { [listenFD, response] in
            FakeSOCKS5Relay.serve(listenFD: listenFD, response: response, relay: self)
        }
        self.thread = thread
        thread.start()
    }

    func stop() {
        #if canImport(Darwin)
        shutdown(listenFD, SHUT_RDWR)
        #endif
        close(listenFD)
    }

    private static func serve(listenFD: Int32, response: Data, relay: FakeSOCKS5Relay) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        do {
            // greeting
            let hello = try readSome(client, 2)
            _ = try readSome(client, Int(hello[1]))
            try writeAll(client, Data([5, 0]))

            // connect: VER CMD RSV ATYP LEN DOMAIN PORT
            let head = try readSome(client, 4)
            guard head[3] == 3 else { return }
            let len = try readSome(client, 1)[0]
            let host = String(decoding: try readSome(client, Int(len)), as: UTF8.self)
            _ = try readSome(client, 2)
            relay.lock.lock()
            relay._seenHost = host
            relay.lock.unlock()
            try writeAll(client, Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))

            // request head
            var request = Data()
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let chunk = try readSome(client, 1)
                if chunk.isEmpty { return }
                request.append(chunk)
            }
            let headText = String(decoding: request, as: UTF8.self)
            var bodyLength = 0
            for line in headText.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                bodyLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            var body = Data()
            if bodyLength > 0 {
                body = try readSome(client, bodyLength)
            }
            let firstLine = headText.split(separator: "\r\n").first.map(String.init) ?? ""
            relay.lock.lock()
            relay._seenPath = firstLine.split(separator: " ").dropFirst().first.map(String.init)
            relay._seenBody = body
            relay.lock.unlock()

            try writeAll(client, response)
        } catch {
            return
        }
    }

    private static func readSome(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, count))
        while out.count < count {
            let n = recv(fd, &buffer, count - out.count, 0)
            if n <= 0 { throw SOCKS5Error.proxy("fake read") }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let flags: Int32
                #if canImport(Darwin)
                flags = 0
                #else
                flags = Int32(MSG_NOSIGNAL)
                #endif
                let n = send(fd, base.advanced(by: sent), raw.count - sent, flags)
                if n <= 0 { throw SOCKS5Error.proxy("fake write") }
                sent += n
            }
        }
    }
}
