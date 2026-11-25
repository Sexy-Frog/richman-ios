import SwiftUI
import UIKit
import VisionKit
import RichManCore

/// Friend-add: show my invite code, or paste a peer's to add them. The QR render
/// + camera scan land next; for now the invite is produced via the CryptoProvider
/// (mock in Simulator) and exchanged as text so the flow is testable.
struct AddFriendView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var tor: TorSession
    @Environment(\.dismiss) private var dismiss
    @State private var myInvite = ""
    @State private var scanned = ""
    @State private var showScanner = false
    @State private var busy = false
    @State private var info: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("自分の招待コード") {
                    if myInvite.isEmpty {
                        Button {
                            Task { await makeInvite() }
                        } label: {
                            HStack {
                                Text(busy ? "作成中…" : "招待コードを作成")
                                if busy { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(busy)
                    } else {
                        if let qr = QRCode.image(from: myInvite) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable().scaledToFit()
                                .frame(maxWidth: 220)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        Text("相手にこのQRを見せて読み取ってもらいます。")
                            .font(.caption).foregroundStyle(RM.onSurfaceVariant)
                        Text(myInvite).font(.footnote.monospaced()).textSelection(.enabled)
                        Button("コードをコピー") {
                            UIPasteboard.general.string = myInvite
                            info = "招待コードをコピーしました。"
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                Section("相手を追加") {
                    Button {
                        if DataScannerViewController.isSupported {
                            showScanner = true
                        } else {
                            error = "この端末ではQRスキャンを利用できません。コードを貼り付けてください。"
                        }
                    } label: {
                        Label("QRコードをスキャン", systemImage: "qrcode.viewfinder")
                    }
                    TextField("招待コードを貼り付け", text: $scanned, axis: .vertical)
                    Button(busy ? "追加中…" : "追加") { Task { await add() } }
                        .disabled(busy || scanned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("カメラが使えない場合は、コードを貼り付けて追加できます。")
                        .font(.caption).foregroundStyle(RM.onSurfaceVariant)
                }
                if let info { Text(info).foregroundStyle(RM.primary) }
                if let error { Text(error).foregroundStyle(RM.error) }
            }
            .navigationTitle("友だちを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
            }
            .sheet(isPresented: $showScanner) {
                ZStack(alignment: .topTrailing) {
                    QRScannerView { code in
                        showScanner = false
                        scanned = code
                        Task { await add() }
                    }
                    .ignoresSafeArea()

                    Button("閉じる") { showScanner = false }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
            }
        }
    }

    private func makeInvite() async {
        error = nil
        busy = true
        defer { busy = false }
        // Prefer the real onion-relay invite when Tor is up and real crypto is
        // linked. The mock bundle fails `PrekeyBundle.decode`, which falls back
        // to the self-contained Simulator invite.
        if let transport = tor.readyTransport {
            if let remote = try? await store.makeRelayInvite(using: transport) {
                myInvite = remote
                info = "Tor経由の招待を作成しました（有効期限 15分・1回限り）。"
                return
            }
        }
        do {
            myInvite = try store.makeInvite()
            info = tor.supportsTor
                ? "オフライン用の招待を作成しました。Tor接続後に作り直してください。"
                : nil
        } catch {
            self.error = "招待の作成に失敗しました: \(error)"
        }
    }

    private func add() async {
        error = nil; info = nil
        busy = true
        defer { busy = false }
        do {
            let c = try await store.addFriend(inviteText: scanned, using: tor.readyTransport)
            info = "\(c.name) を追加しました。"
            scanned = ""
        } catch let e as InviteError {
            error = message(for: e)
        } catch {
            self.error = "追加に失敗しました: \(error)"
        }
    }

    private func message(for e: InviteError) -> String {
        switch e {
        case .malformed:           return "招待コードを読み取れませんでした。"
        case .unsupportedVersion:  return "未対応の招待コードです。"
        case .selfAdd:             return "自分自身は追加できません。"
        case .mismatchedIdentity, .mismatchedRouting, .mismatchedMailbox:
            return "招待コードが一致しません。"
        }
    }
}
