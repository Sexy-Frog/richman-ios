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

        let alice = Contact(id: "demo-alice", name: "アリス", unread: 2)
        let bob = Contact(id: "demo-bob", name: "ボブ")

        var aliceMessages = [
            message("a1", "明日の待ち合わせ、渋谷でいい？", minutesAgo: 46),
            message("a2", "OK、11時にハチ公前で", mine: true, minutesAgo: 44, delivery: .read),
            message("a3", "了解！遅れそうなら連絡するね", minutesAgo: 42),
            message("a4", "ありがとう", mine: true, minutesAgo: 40, delivery: .delivered),
            message("a5", "写真も送っておくね", minutesAgo: 12),
        ]
        if let demoImage = MediaStore.demoImage() {
            aliceMessages.append(
                ChatMessage(
                    id: "a6", body: "", mine: false,
                    ts: now.addingTimeInterval(-11 * 60),
                    kind: .image, mediaName: demoImage
                )
            )
        }

        let bobMessages = [
            message("b1", "資料ありがとう！", minutesAgo: 180),
            message("b2", "確認して感想送るね", mine: true, minutesAgo: 178, delivery: .read),
            message("b3", "助かる〜", minutesAgo: 176),
        ]

        store.seed(
            contacts: [alice, bob],
            messages: [alice.id: aliceMessages, bob.id: bobMessages]
        )

        let group = ChatGroup(id: "demo-group", name: "週末の予定", memberIds: [alice.id, bob.id])
        let groupMessages = [
            ChatMessage(
                id: "g1", body: "土曜の夜、空いてる？", mine: false,
                ts: now.addingTimeInterval(-90 * 60), senderName: "アリス"
            ),
            ChatMessage(
                id: "g2", body: "空いてる！", mine: true,
                ts: now.addingTimeInterval(-88 * 60)
            ),
            ChatMessage(
                id: "g3", body: "じゃあ19時に渋谷で", mine: false,
                ts: now.addingTimeInterval(-86 * 60), senderName: "ボブ"
            ),
        ]
        store.seedGroups([group], messages: [group.id: groupMessages])
    }
}
