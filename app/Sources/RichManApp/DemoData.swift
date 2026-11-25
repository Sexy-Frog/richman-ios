import Foundation

/// Deterministic content for screenshot builds and manual demos.
/// Activated with the DEBUG launch argument `-rm.demo 1`; release builds ignore it.
@MainActor
enum DemoData {
    static var enabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "rm.demo")
        #else
        return false
        #endif
    }

    static func seed(into store: ChatStore) {
        guard enabled, store.contacts.isEmpty else { return }
        let now = Date()

        func message(_ id: String,
                     _ body: String,
                     mine: Bool = false,
                     minutesAgo: Int,
                     kind: ChatMessage.Kind = .text,
                     delivery: ChatMessage.Delivery = .read) -> ChatMessage {
            ChatMessage(
                id: id,
                body: body,
                mine: mine,
                ts: now.addingTimeInterval(Double(-minutesAgo) * 60),
                kind: kind,
                delivery: delivery
            )
        }

        let alice = Contact(id: "demo-alice", name: "アリス")
        let bob = Contact(id: "demo-bob", name: "ボブ")

        let aliceMessages = [
            message("a1", "明日の待ち合わせ、渋谷でいい？", minutesAgo: 46),
            message("a2", "OK、11時にハチ公前で", mine: true, minutesAgo: 44, delivery: .read),
            message("a3", "了解！遅れそうなら連絡するね", minutesAgo: 42),
            message("a4", "ありがとう", mine: true, minutesAgo: 40, delivery: .delivered),
            message("a5", "写真も送っておくね", minutesAgo: 12, kind: .image),
        ]

        let bobMessages = [
            message("b1", "資料ありがとう！", minutesAgo: 180),
            message("b2", "確認して感想送るね", mine: true, minutesAgo: 178, delivery: .read),
            message("b3", "助かる〜", minutesAgo: 176),
        ]

        store.seed(
            contacts: [alice, bob],
            messages: [alice.id: aliceMessages, bob.id: bobMessages]
        )
    }
}
