import SwiftUI
import UIKit
import VisionKit
import RichManCore

/// Friend-add, ported from the Android screen: a large personal QR/link,
/// copy/share/scan actions, refresh, and a paste field that accepts the invite
/// link, a bare code, or the legacy raw JSON.
struct AddFriendView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var tor: TorSession
    @Environment(\.dismiss) private var dismiss

    @State private var myInvite = ""
    @State private var shareURL: URL?
    @State private var qr: UIImage?
    @State private var scanned = ""
    @State private var showScanner = false
    @State private var busy = false
    @State private var generating = true
    @State private var info: String?
    @State private var error: String?

    init(initialCode: String = "") {
        _scanned = State(initialValue: initialCode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    inviteCard
                    actions
                    refreshButton
                    disclaimer
                    if let info {
                        Text(info)
                            .font(.caption)
                            .foregroundStyle(RM.primary)
                            .multilineTextAlignment(.center)
                    }
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(RM.error)
                            .multilineTextAlignment(.center)
                    }
                    Divider()
                    codeInput
                }
                .padding(20)
            }
            .background(RM.background)
            .navigationTitle("友だちを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                if myInvite.isEmpty { await makeInvite() }
                if !scanned.isEmpty {
                    info = "招待リンクを読み込みました。「追加」を押してください。"
                }
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

    // MARK: invite card

    private var inviteCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                if let qr {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else if generating {
                    ProgressView().tint(.black)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.largeTitle)
                            .foregroundStyle(.black.opacity(0.35))
                        Text("QRを生成できません")
                            .font(.caption2)
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
            }
            .frame(width: 240, height: 240)

            Text(store.displayName)
                .font(.headline)

            if let shareURL {
                Text(shareURL.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(RM.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RM.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 22) {
            Button { copyLink() } label: {
                actionLabel("コピー", "doc.on.doc")
            }
            .buttonStyle(.plain)

            if let shareText {
                ShareLink(item: shareText) {
                    actionLabel("共有", "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            } else {
                actionLabel("共有", "square.and.arrow.up")
                    .opacity(0.35)
            }

            Button { startScan() } label: {
                actionLabel("スキャン", "qrcode.viewfinder")
            }
            .buttonStyle(.plain)
        }
        .disabled(busy || generating)
        .opacity(busy || generating ? 0.45 : 1)
    }

    private var refreshButton: some View {
        Button {
            Task { await makeInvite(regenerate: true) }
        } label: {
            Label("QRを更新", systemImage: "arrow.clockwise")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RM.primary)
        }
        .buttonStyle(.plain)
        .disabled(busy || generating)
        .opacity(busy || generating ? 0.45 : 1)
    }

    private var disclaimer: some View {
        Text("QRコードと招待リンクは信頼できる相手とだけ共有してください。リンクは1回限り・15分で失効します。")
            .font(.caption2)
            .foregroundStyle(RM.onSurfaceVariant)
            .multilineTextAlignment(.center)
    }

    // MARK: paste field

    private var codeInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("招待リンクを貼り付け")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                TextField("招待リンクまたはコード", text: $scanned, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(RM.outline, lineWidth: 1)
                    )

                Button {
                    Task { await add() }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.headline)
                        .foregroundStyle(RM.onPrimary)
                        .frame(width: 48, height: 48)
                        .background(RM.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(busy || scanned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(
                    busy || scanned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? 0.45 : 1
                )
            }

            Text("カメラが使えない場合は、相手から届いた招待リンクを貼り付けて追加できます。")
                .font(.caption2)
                .foregroundStyle(RM.onSurfaceVariant)
        }
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.caption2)
        }
        .frame(width: 70, height: 56)
        .foregroundStyle(RM.primary)
    }

    private var shareText: String? {
        if let shareURL { return shareURL.absoluteString }
        return myInvite.isEmpty ? nil : myInvite
    }

    // MARK: actions

    private func makeInvite(regenerate: Bool = false) async {
        if regenerate {
            myInvite = ""
            shareURL = nil
            qr = nil
        }
        error = nil
        info = nil
        generating = true
        busy = true
        defer {
            generating = false
            busy = false
        }

        var raw: String?
        var relayed = false
        if let transport = tor.readyTransport,
           let remote = try? await store.makeRelayInvite(using: transport) {
            raw = remote
            relayed = true
        }
        if raw == nil {
            raw = try? store.makeInvite()
        }
        guard let raw else {
            error = "招待コードを作成できませんでした。しばらく待って再試行してください。"
            return
        }

        myInvite = raw
        let url = InviteLink.url(for: raw)
        shareURL = url
        qr = QRCode.image(from: url?.absoluteString ?? raw)
        if relayed {
            info = "招待リンクを作成しました（有効期限 15分・1回限り）。"
        } else if tor.supportsTor {
            info = "オフライン用の招待を作成しました。Tor接続後に作り直してください。"
        }
    }

    private func copyLink() {
        guard let shareText else { return }
        UIPasteboard.general.string = shareText
        info = "招待リンクをコピーしました。"
    }

    private func startScan() {
        if DataScannerViewController.isSupported {
            showScanner = true
        } else {
            error = "この端末ではQRスキャンを利用できません。リンクを貼り付けてください。"
        }
    }

    private func add() async {
        error = nil
        info = nil
        guard let raw = InviteLink.normalize(scanned) else {
            error = "招待リンクを読み取れませんでした。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let contact = try await store.addFriend(
                inviteText: raw,
                using: tor.readyTransport
            )
            info = "\(contact.name) を追加しました。"
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
