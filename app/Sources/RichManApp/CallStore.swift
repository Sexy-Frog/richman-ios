import SwiftUI
import UIKit
import AVFoundation
import RichManCore

/// App-to-app voice call. Signaling and ADPCM audio travel through the same
/// libsignal-encrypted relay envelopes as messages (no server or third party
/// sees or routes the call). Tor adds noticeable latency.
@MainActor
final class CallStore: ObservableObject {
    enum Phase: Equatable {
        case idle, calling, incoming, active, ended
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName = ""
    @Published private(set) var seconds = 0
    @Published private(set) var muted = false
    @Published private(set) var speaker = false
    @Published private(set) var error: String?

    private(set) var peerId = ""
    private var callId = ""
    private var timer: Timer?
    private var timeoutTask: Task<Void, Never>?
    private var audio: CallAudioEngine?
    private var seq: Int64 = 0
    private var negotiatedRate = 16_000

    /// Wired by RootView.
    var sendPayload: ((String, Data) -> Void)?
    var onFastPolling: ((Bool, String?) -> Void)?
    var nameResolver: ((String) -> String?)?

    init() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "rm.call") {
        case "incoming":
            peerName = "アリス"
            phase = .incoming
        case "active":
            peerName = "アリス"
            phase = .active
            startTimer()
        default:
            break
        }
        #endif
    }

    // MARK: outgoing

    func startCall(peerId: String, name: String) {
        guard phase == .idle || phase == .ended else { return }
        ensureMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.error = "マイクの権限がありません"
                return
            }
            self.callId = UUID().uuidString
            self.peerId = peerId
            self.peerName = name
            self.error = nil
            self.phase = .calling
            self.negotiatedRate = 16_000
            self.send(CallSignal(t: MessageType.callOffer.rawValue,
                                 id: self.callId, sr: 16_000))
            self.armTimeout("応答がありません")
        }
    }

    func accept() {
        guard phase == .incoming else { return }
        send(CallSignal(t: MessageType.callAnswer.rawValue,
                        id: callId, sr: negotiatedRate))
        activate()
    }

    func decline() {
        if !callId.isEmpty {
            send(CallSignal(t: MessageType.callEnd.rawValue,
                            id: callId, why: "decline"))
        }
        finish()
    }

    func end() {
        if !callId.isEmpty {
            send(CallSignal(t: MessageType.callEnd.rawValue, id: callId))
        }
        finish()
    }

    func toggleMute() {
        guard phase == .active else { return }
        muted.toggle()
        audio?.setMuted(muted)
    }

    func toggleSpeaker() {
        guard phase == .active else { return }
        speaker.toggle()
        audio?.setSpeaker(speaker)
    }

    // MARK: inbound

    func handleSignal(from peerId: String, signal: CallSignal) {
        switch signal.t {
        case MessageType.callOffer.rawValue:
            guard phase == .idle || phase == .ended else {
                send(CallSignal(t: MessageType.callEnd.rawValue,
                                id: signal.id, why: "busy"), to: peerId)
                return
            }
            callId = signal.id
            self.peerId = peerId
            let fallback = signal.n?.isEmpty == false ? signal.n! : "着信"
            peerName = nameResolver?(peerId) ?? fallback
            negotiatedRate = min(16_000, signal.sr ?? 8_000)
            error = nil
            phase = .incoming
            if UIApplication.shared.applicationState != .active {
                NotificationManager.shared.incomingCall(from: peerName)
            }
            armTimeout("応答がありません")

        case MessageType.callAnswer.rawValue:
            guard phase == .calling, signal.id == callId else { return }
            negotiatedRate = signal.sr ?? 8_000
            activate()

        case MessageType.callEnd.rawValue:
            guard signal.id == callId, peerId == self.peerId else { return }
            if signal.why == "busy" {
                finish(error: "通話中です")
            } else if signal.why == "decline" {
                finish(error: "通話が拒否されました")
            } else if signal.why == "mic" || signal.why == "audio" {
                finish(error: "相手が通話を開始できませんでした")
            } else {
                finish()
            }

        default:
            break
        }
    }

    func handleAudio(from peerId: String, packet: CallAudio) {
        guard phase == .active, packet.id == callId, peerId == self.peerId else {
            return
        }
        guard let data = try? Base64URL.decode(packet.d) else { return }
        audio?.enqueue(data)
    }

    // MARK: audio lifecycle

    private func activate() {
        timeoutTask?.cancel()
        timeoutTask = nil
        phase = .active
        seconds = 0
        seq = 0
        startTimer()
        onFastPolling?(true, peerId)
        ensureMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.send(CallSignal(t: MessageType.callEnd.rawValue,
                                     id: self.callId, why: "mic"))
                self.finish(error: "マイクの権限がありません")
                return
            }
            do {
                let engine = CallAudioEngine(rate: self.negotiatedRate)
                engine.onChunk = { [weak self] chunk in
                    self?.sendAudio(chunk)
                }
                try engine.start(speaker: self.speaker)
                self.audio = engine
            } catch {
                self.send(CallSignal(t: MessageType.callEnd.rawValue,
                                     id: self.callId, why: "audio"))
                self.finish(error: "通話を開始できませんでした")
            }
        }
    }

    private func sendAudio(_ data: Data) {
        guard phase == .active, !callId.isEmpty else { return }
        let packet = CallAudio(
            id: callId, peer: peerId, seq: seq, d: Base64URL.encode(data)
        )
        seq += 1
        guard let json = try? packet.toPayloadJSON() else { return }
        sendPayload?(peerId, json)
    }

    private func send(_ signal: CallSignal, to peerId: String? = nil) {
        guard let json = try? signal.toPayloadJSON() else { return }
        sendPayload?(peerId ?? self.peerId, json)
    }

    private func finish(error: String? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        timer?.invalidate()
        timer = nil
        audio?.stop()
        audio = nil
        onFastPolling?(false, nil)
        callId = ""
        seconds = 0
        muted = false
        speaker = false
        self.error = error
        phase = .idle
    }

    private func armTimeout(_ message: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.phase == .calling || self.phase == .incoming else { return }
            if !self.callId.isEmpty {
                self.send(CallSignal(t: MessageType.callEnd.rawValue,
                                     id: self.callId, why: "timeout"))
            }
            self.finish(error: message)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .active else { return }
                self.seconds += 1
            }
        }
    }

    private func ensureMic(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
