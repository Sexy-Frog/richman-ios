import Foundation
import RichManCore
import Darwin

/// Loopback HTTP server that MapLibre talks to. MapLibre has its own HTTP
/// stack (and no SOCKS support we can rely on), so instead of leaking tile
/// requests to the CDN we serve the style/tiles/glyphs/sprite from
/// `127.0.0.1` and fetch every resource through the onion relay over Tor.
///
/// This mirrors the Android `MapProxy`: the style JSON is bundled with
/// `__MAP_BASE__` placeholders, and only the loopback origin is substituted.
final class MapProxy: @unchecked Sendable {
    static let shared = MapProxy()

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var port: UInt16 = 0
    private var transport: RelayTransport?
    private var resolvedStyle: Data?
    private let workers = DispatchSemaphore(value: 12)
    private let prefetchWorkers = DispatchSemaphore(value: 4)
    private let memory = NSCache<NSString, NSData>()
    private let cacheDirectory: URL

    private init() {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        cacheDirectory = base.appendingPathComponent(
            "RichManMap", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        memory.countLimit = 256
    }

    var styleURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return urlLocked()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return port > 0
    }

    /// Starts once; subsequent calls return the existing URL.
    @discardableResult
    func start(transport: RelayTransport) -> URL? {
        lock.lock()
        if port > 0 {
            let url = urlLocked()
            lock.unlock()
            return url
        }
        guard let template = Self.loadTemplate() else {
            lock.unlock()
            return nil
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lock.unlock()
            return nil
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            close(fd)
            lock.unlock()
            return nil
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            lock.unlock()
            return nil
        }

        port = UInt16(bigEndian: boundAddress.sin_port)
        listenFD = fd
        self.transport = transport
        resolvedStyle = Self.resolve(template, base: "http://127.0.0.1:\(port)")
        let url = urlLocked()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "RichManMapProxy"
        thread.stackSize = 512 * 1024
        lock.unlock()
        thread.start()

        // Warm the sprite (needed for every symbol layer) so the first map
        // open does not wait for it after the style loads.
        for path in ["sprites/ofm_f384/ofm.png", "sprites/ofm_f384/ofm.json"] {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, self.cached(path) == nil,
                      let data = self.fetch(path) else { return }
                self.store(data, for: path)
            }
        }
        return url
    }

    func stop() {
        lock.lock()
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
        listenFD = -1
        port = 0
        transport = nil
        resolvedStyle = nil
        lock.unlock()
    }

    private func urlLocked() -> URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/style.json")
    }

    // MARK: accept / request

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            workers.wait()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handle(client)
                self?.workers.signal()
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one,
                   socklen_t(MemoryLayout<Int32>.size))

        guard let path = readRequestPath(client) else {
            respond(client, status: 400, type: "text/plain", body: Data())
            return
        }

        if path == "/style.json" {
            guard let style = resolvedStyle else {
                respond(client, status: 503, type: "text/plain", body: Data())
                return
            }
            respond(client, status: 200, type: "application/json", body: style)
            return
        }

        guard path.hasPrefix("/v1/map/") else {
            respond(client, status: 404, type: "text/plain", body: Data())
            return
        }
        let subpath = String(path.dropFirst("/v1/map/".count))
        // Never let a request climb out of the relay's map namespace.
        guard !subpath.isEmpty, !subpath.contains("..") else {
            respond(client, status: 404, type: "text/plain", body: Data())
            return
        }
        // Glyph paths contain spaces ("Noto Sans Regular"); a raw space would
        // split the HTTP request line. The relay unquotes before fetching.
        let encoded = subpath.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? subpath
        if let hit = cached(subpath) {
            respond(client, status: 200, type: Self.contentType(subpath), body: hit)
            return
        }
        guard let data = fetch(encoded) else {
            // 5xx is treated as temporary by MapLibre, so it retries.
            respond(client, status: 503, type: "text/plain", body: Data())
            return
        }
        store(data, for: subpath)
        respond(client, status: 200, type: Self.contentType(subpath), body: data)
    }

    // MARK: cache

    private func cached(_ subpath: String) -> Data? {
        if let hit = memory.object(forKey: subpath as NSString) {
            return hit as Data
        }
        guard let data = try? Data(contentsOf: cacheURL(for: subpath)) else {
            return nil
        }
        memory.setObject(data as NSData, forKey: subpath as NSString)
        return data
    }

    private func store(_ data: Data, for subpath: String) {
        memory.setObject(data as NSData, forKey: subpath as NSString)
        try? data.write(to: cacheURL(for: subpath), options: .atomic)
    }

    private func cacheURL(for subpath: String) -> URL {
        var name = subpath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if name.count > 180 { name = String(name.suffix(180)) }
        return cacheDirectory.appendingPathComponent(name)
    }

    /// Warm the vector tiles around a coordinate. Called when the zone editor
    /// opens so MapLibre finds them in the disk cache instead of fetching each
    /// tile through Tor while the user watches an empty screen.
    func prefetch(latitude: Double, longitude: Double, zoom: Double = 15) {
        guard isRunning else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let baseZoom = max(8, min(14, Int(floor(zoom))))
            for level in [baseZoom, baseZoom - 1, baseZoom - 2] where level >= 8 {
                let (cx, cy) = Self.tile(
                    latitude: latitude, longitude: longitude, zoom: level
                )
                let radius = level == baseZoom ? 1 : 0
                let count = 1 << level
                for dx in -radius...radius {
                    for dy in -radius...radius {
                        let x = cx + dx
                        let y = cy + dy
                        guard (0..<count).contains(x),
                              (0..<count).contains(y) else { continue }
                        let path = "tiles/\(level)/\(x)/\(y).pbf"
                        if self.cached(path) != nil { continue }
                        self.prefetchWorkers.wait()
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            guard let self else { return }
                            if let data = self.fetch(path) {
                                self.store(data, for: path)
                            }
                            self.prefetchWorkers.signal()
                        }
                    }
                }
            }
        }
    }

    private static func tile(
        latitude: Double,
        longitude: Double,
        zoom: Int
    ) -> (Int, Int) {
        let n = pow(2.0, Double(zoom))
        let x = Int(floor((longitude + 180.0) / 360.0 * n))
        let lat = latitude * .pi / 180.0
        let y = Int(floor((1.0 - log(tan(lat) + 1.0 / cos(lat)) / .pi) / 2.0 * n))
        return (x, y)
    }

    /// Fetch one map resource through the relay. Blocking (the caller is a
    /// worker queue) with a hard cap so a dead circuit cannot pin a thread.
    private func fetch(_ subpath: String) -> Data? {
        guard let transport else { return nil }
        final class Box: @unchecked Sendable { var value: Data? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = try? await RelayClient(transport: transport)
                .getMapResource(path: subpath)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 45)
        return box.value
    }

    // MARK: wire helpers

    private func readRequestPath(_ client: Int32) -> String? {
        var head = Data()
        var byte: UInt8 = 0
        while head.count < 16 * 1024 {
            let n = recv(client, &byte, 1, 0)
            if n <= 0 { break }
            head.append(byte)
            if head.count >= 4, head.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        guard let text = String(data: head, encoding: .utf8),
              let line = text.split(separator: "\r\n").first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let raw = parts[1].split(separator: "?").first.map(String.init) ?? String(parts[1])
        return raw.removingPercentEncoding ?? raw
    }

    private func respond(_ client: Int32, status: Int, type: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Service Unavailable"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: public, max-age=86400\r\n"
        head += "Connection: close\r\n\r\n"
        writeAll(client, Data(head.utf8))
        if !body.isEmpty { writeAll(client, body) }
    }

    private func writeAll(_ client: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var sent = 0
            while sent < raw.count {
                let n = send(client, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
            return sent
        }
    }

    private static func contentType(_ path: String) -> String {
        if path.hasSuffix(".pbf") { return "application/x-protobuf" }
        if path.hasSuffix(".png") { return "image/png" }
        if path.hasSuffix(".json") { return "application/json" }
        return "application/octet-stream"
    }

    private static func loadTemplate() -> Data? {
        guard let url = Bundle.main.url(
            forResource: "map_style_ja", withExtension: "json"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func resolve(_ template: Data, base: String) -> Data? {
        guard let text = String(data: template, encoding: .utf8) else { return nil }
        return Data(text.replacingOccurrences(of: "__MAP_BASE__", with: base).utf8)
    }
}
