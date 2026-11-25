#if DEBUG
import Foundation
import UIKit
import RichManCore

/// DEBUG-only simulator E2E driver. It is inert unless launched with
/// `-rm.e2eRole host|join`; it drives the real relay/crypto stack headlessly so
/// CI can verify invite → 1:1 text → image → location → group → Tor map
/// without an Apple Developer account (two simulators, two Tor clients).
///
/// Results are written to `Documents/e2e.json` and read by the workflow via
/// `simctl get_app_container`.
@MainActor
enum E2E {
    static var role: String? {
        UserDefaults.standard.string(forKey: "rm.e2eRole")
    }

    static func runIfRequested(store: ChatStore, tor: TorSession) async {
        guard let role else { return }
        do {
            switch role {
            case "host": try await runHost(store: store, tor: tor)
            case "join": try await runJoin(store: store, tor: tor)
            default: report(["done": true, "error": "unknown role"])
            }
        } catch {
            report(["role": role, "done": true, "error": String(describing: error)])
        }
    }

    // MARK: host

    private static func runHost(store: ChatStore, tor: TorSession) async throws {
        report(["role": "host", "phase": "tor"])
        let transport = try await waitForTor(tor)
        let mapOK = await verifyTorMap(tor: tor)
        report(["phase": "invite", "map": mapOK])

        var invite = ""
        for attempt in 0..<10 {
            do {
                invite = try await store.makeRelayInvite(using: transport)
                break
            } catch {
                if attempt == 9 { throw error }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        report(["phase": "invite-ready", "invite": invite])

        let deadline = Date().addingTimeInterval(420)
        var peer: String?
        var imageSeen = false
        var placeSeen = false
        var groupSeen = false
        var groupSentAt: Date?

        while Date() < deadline {
            if peer == nil,
               let found = store.contacts.first(where: {
                   !$0.official && !store.messages(for: $0.id).isEmpty
               }) {
                peer = found.id
                report(["phase": "connected", "peer": found.id])
                store.send(to: found.id, text: "pong")
                store.sendImage(to: found.id, data: testImage())
                store.sendLocation(
                    to: found.id,
                    latitude: 35.6812,
                    longitude: 139.7671,
                    accuracy: 10
                )
            }

            if let peer {
                if store.messages(for: peer).contains(where: { $0.kind == .image }) {
                    imageSeen = true
                }
                if store.places[peer] != nil { placeSeen = true }

                if !groupSeen, imageSeen, placeSeen {
                    let group = store.createGroup(name: "E2E", memberIds: [peer])
                    store.send(toGroup: group.id, text: "group-hello")
                    groupSeen = true
                    groupSentAt = Date()
                    report(["phase": "group", "group": group.id])
                }
            }

            if imageSeen, placeSeen, groupSeen {
                // Allow the joiner to receive the invite/group message before
                // the workflow asserts both reports.
                if let sentAt = groupSentAt,
                   Date().timeIntervalSince(sentAt) > 20 {
                    report([
                        "done": true,
                        "image": imageSeen,
                        "place": placeSeen,
                        "group": groupSeen,
                        "peer": peer ?? "",
                    ])
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        report([
            "done": true,
            "error": "timeout",
            "image": imageSeen,
            "place": placeSeen,
            "group": groupSeen,
            "peer": peer ?? "",
        ])
    }

    // MARK: join

    private static func runJoin(store: ChatStore, tor: TorSession) async throws {
        report(["role": "join", "phase": "tor"])
        let transport = try await waitForTor(tor)

        guard let encoded = UserDefaults.standard.string(forKey: "rm.e2eInvite"),
              let data = try? Base64URL.decode(encoded),
              let invite = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "e2e", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing invite"])
        }

        report(["phase": "add"])
        var added: Contact?
        for attempt in 0..<10 {
            do {
                added = try await store.addFriend(
                    inviteText: invite, using: transport
                )
                break
            } catch {
                if attempt == 9 { throw error }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        guard let contact = added else {
            throw NSError(domain: "e2e", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "addFriend failed"])
        }
        report(["phase": "joined", "peer": contact.id])
        store.send(to: contact.id, text: "ping")

        let deadline = Date().addingTimeInterval(420)
        var textSeen = false
        var imageSeen = false
        var placeSeen = false
        var groupSeen = false
        var mediaSent = false

        while Date() < deadline {
            let messages = store.messages(for: contact.id)
            if messages.contains(where: { !$0.mine && $0.body == "pong" }) {
                textSeen = true
                if !mediaSent {
                    store.sendImage(to: contact.id, data: testImage())
                    store.sendLocation(
                        to: contact.id,
                        latitude: 35.6580,
                        longitude: 139.7016,
                        accuracy: 12
                    )
                    mediaSent = true
                    report(["phase": "media-sent"])
                }
            }
            if messages.contains(where: { !$0.mine && $0.kind == .image }) {
                imageSeen = true
            }
            if store.places[contact.id] != nil { placeSeen = true }
            if let group = store.groups.first(where: { $0.name == "E2E" }) {
                if store.messages(forGroup: group.id).contains(where: { !$0.mine }) {
                    groupSeen = true
                }
            }

            if textSeen, imageSeen, placeSeen, groupSeen {
                report([
                    "done": true,
                    "text": textSeen,
                    "image": imageSeen,
                    "place": placeSeen,
                    "group": groupSeen,
                ])
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        report([
            "done": true,
            "error": "timeout",
            "text": textSeen,
            "image": imageSeen,
            "place": placeSeen,
            "group": groupSeen,
        ])
    }

    // MARK: helpers

    private static func waitForTor(_ tor: TorSession) async throws -> RelayTransport {
        var lastNote = Date.distantPast
        for step in 0..<210 {
            if let transport = tor.readyTransport,
               (try? await RelayClient(transport: transport).ping()) == true {
                report(["phase": "tor-ready"])
                return transport
            }
            if step % 5 == 0 { tor.checkNow() }
            if Date().timeIntervalSince(lastNote) > 10 {
                lastNote = Date()
                report([
                    "tor": tor.statusText,
                    "configured": tor.configured,
                    "supports": tor.supportsTor,
                    "lastError": tor.lastError ?? "",
                ])
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw NSError(domain: "e2e", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Tor/relay timeout (\(tor.statusText))",
        ])
    }

    /// Exercise the Tor map path without MapLibre: fetch the bundled style and
    /// one vector tile through the loopback proxy (which uses SOCKS → relay).
    private static func verifyTorMap(tor: TorSession) async -> Bool {
        guard let styleURL = tor.mapStyleURL else { return false }
        guard let (styleData, _) = try? await URLSession.shared.data(from: styleURL),
              let style = String(data: styleData, encoding: .utf8),
              style.contains("/v1/map/tiles/"),
              let port = styleURL.port,
              let tileURL = URL(string:
                "http://127.0.0.1:\(port)/v1/map/tiles/14/14553/6452.pbf") else {
            return false
        }
        guard let (tile, response) = try? await URLSession.shared.data(from: tileURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              tile.count > 100 else {
            return false
        }
        return true
    }

    private static func testImage() -> Data {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.23, green: 0.46, blue: 0.94, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 18, y: 18, width: 28, height: 28))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    private static func report(_ values: [String: Any]) {
        let url = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("e2e.json")
        var current = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        )) as? [String: Any] ?? [:]
        current.merge(values) { _, new in new }
        current["updated"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(
            withJSONObject: current, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: [.atomic])
        }
        let line = values.map { "\($0.key)=\($0.value)" }
            .sorted().joined(separator: " ")
        print("E2E \(line)")
    }
}
#endif
