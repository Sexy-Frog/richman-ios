import XCTest
@testable import RichManCore

private struct CapturedRequest {
    let method: String
    let path: String
    let contentType: String?
    let body: Data?
}

private final class MockTransport: RelayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [CapturedRequest] = []
    private let responder: (String, String, Data?) -> RelayResponse

    var calls: [CapturedRequest] { lock.lock(); defer { lock.unlock() }; return _calls }

    init(responder: @escaping (String, String, Data?) -> RelayResponse) {
        self.responder = responder
    }

    func perform(method: String, path: String, contentType: String?, body: Data?) async throws -> RelayResponse {
        lock.lock()
        _calls.append(CapturedRequest(method: method, path: path, contentType: contentType, body: body))
        lock.unlock()
        return responder(method, path, body)
    }
}

private func jsonResponse(_ dict: [String: Any], status: Int = 200) -> RelayResponse {
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return RelayResponse(status: status, body: data)
}

final class RelayClientTests: XCTestCase {

    func testSendBuildsJSONBody() async throws {
        let transport = MockTransport { _, _, _ in jsonResponse([:]) }
        let client = RelayClient(transport: transport)
        let box = secureRandomData(32)
        let env = secureRandomData(Wire.size)

        try await client.send(to: box, envelope: env)

        let call = transport.calls[0]
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "v1/send")
        XCTAssertEqual(call.contentType, "application/json; charset=utf-8")
        let obj = try JSONSerialization.jsonObject(with: call.body!) as! [String: Any]
        XCTAssertEqual(obj["to"] as? String, Base64URL.encode(box))
        XCTAssertEqual(obj["env"] as? String, Base64URL.encode(env))
    }

    func testFetchParsesMessages() async throws {
        let env = secureRandomData(Wire.size)
        let transport = MockTransport { _, path, _ in
            XCTAssertEqual(path, "v1/fetch")
            return jsonResponse(["msgs": [["id": "m1", "env": Base64URL.encode(env)]]])
        }
        let client = RelayClient(transport: transport)
        let msgs = try await client.fetch(box: secureRandomData(32), wait: 5)
        XCTAssertEqual(msgs, [FetchedMessage(id: "m1", envelope: env)])

        // wait value is carried in the body
        let obj = try JSONSerialization.jsonObject(with: transport.calls[0].body!) as! [String: Any]
        XCTAssertEqual(obj["wait"] as? Int, 5)
    }

    func testFetchEmptyWhenNoMsgs() async throws {
        let transport = MockTransport { _, _, _ in jsonResponse([:]) }
        let client = RelayClient(transport: transport)
        let msgs = try await client.fetch(box: secureRandomData(32))
        XCTAssertTrue(msgs.isEmpty)
    }

    func testPutBlobReturnsId() async throws {
        let transport = MockTransport { _, _, _ in jsonResponse(["id": "blob-123"]) }
        let client = RelayClient(transport: transport)
        let id = try await client.putBlob(Data([1, 2, 3]))
        XCTAssertEqual(id, "blob-123")
        XCTAssertEqual(transport.calls[0].contentType, "application/octet-stream")
    }

    func testPutInviteReturnsToken() async throws {
        let transport = MockTransport { _, _, _ in jsonResponse(["token": "tok-9"]) }
        let client = RelayClient(transport: transport)
        let tok = try await client.putInvite(bundle: Data([9]))
        XCTAssertEqual(tok, "tok-9")
    }

    func testAckSkipsWhenEmpty() async throws {
        let transport = MockTransport { _, _, _ in jsonResponse([:]) }
        let client = RelayClient(transport: transport)
        try await client.ack(box: secureRandomData(32), ids: [])
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testPing() async throws {
        let ok = MockTransport { _, _, _ in RelayResponse(status: 200, body: Data("ok".utf8)) }
        let okReady = try await RelayClient(transport: ok).ping()
        XCTAssertTrue(okReady)
        let down = MockTransport { _, _, _ in RelayResponse(status: 502, body: Data()) }
        let downReady = try await RelayClient(transport: down).ping()
        XCTAssertFalse(downReady)
    }

    func testHttpErrorThrows() async throws {
        let transport = MockTransport { _, _, _ in RelayResponse(status: 500, body: Data("boom".utf8)) }
        let client = RelayClient(transport: transport)
        do {
            try await client.send(to: secureRandomData(32), envelope: secureRandomData(Wire.size))
            XCTFail("expected throw")
        } catch let RelayError.http(code, _) {
            XCTAssertEqual(code, 500)
        }
    }
}
