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
    /// True while the system CallKit UI owns the call (app was backgrounded
    /// when the offer arrived). The in-app overlay stays hidden in that case.
    @Published private(set) var usesSystemUI = false
    private(set) var peerId = ""
    private var callId = ""
    private var timer: Timer?
    private var timeoutTask: Task<Void, Never>?
    private var audio: CallAudioEngine?
    private var seq: Int64 = 0
    private var negotiatedRate = 16_000
    /// Cap on audio packets waiting for Tor. Dropping frames keeps latency
    /// bounded instead of letting the call fall seconds behind.
    private var audioInFlight = 0

    /// Wired by RootView.
    var sendPayload: ((String, Data, Bool, Bool, (() -> Void)?) -> Void)?
    var onFastPolling: ((Bool, String?) -> Void)?
    var nameResolver: ((String) -> String?)?
    /// (peerId, active seconds, outgoing, missed) after a call ends.
    var onCallEnded: ((String, Int, Bool, Bool) -> Void)?
    /// Called after the call is fully torn down (reports the end to CallKit).
    var onCallFinished: (() -> Void)?
    private var isOutgoing = false
    private var wasActive = false
    private var acceptWhenOffered = false

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
            self.isOutgoing = true
            self.wasActive = false
            self.acceptWhenOffered = false
            self.usesSystemUI = false
            self.negotiatedRate = 16_000
            self.send(CallSignal(t: MessageType.callOffer.rawValue,
                                 id: self.callId, sr: 16_000))
            self.onFastPolling?(true, self.peerId)
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

    /// CallKit answer. If the encrypted offer has not arrived yet (network is
    /// still fetching), connect as soon as it does.
    func acceptFromSystem() {
        if phase == .incoming {
            accept()
        } else if phase == .idle || phase == .ended {
            acceptWhenOffered = true
        }
    }

    /// CallKit decline/end. Works even if the offer has not been fetched.
    func endFromSystem() {
        if phase == .incoming {
            decline()
        } else if phase == .calling || phase == .active {
            end()
        } else {
            finish()
        }
    }

    func setMutedFromSystem(_ value: Bool) {
        guard phase == .active else { return }
        muted = value
        audio?.setMuted(value)
    }

    func setUsesSystemUI(_ value: Bool) {
        usesSystemUI = value
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
            isOutgoing = false
            wasActive = false
            let fallback = signal.n?.isEmpty == false ? signal.n! : "着信"
            peerName = nameResolver?(peerId) ?? fallback
            negotiatedRate = min(16_000, signal.sr ?? 8_000)
            error = nil
            phase = .incoming
            // The VoIP push already put the native call screen on the lock
            // screen; update its caller name once the offer is decrypted.
            CallKitManager.shared.updateCaller(name: peerName)
            armTimeout("応答がありません")
            if acceptWhenOffered {
                acceptWhenOffered = false
                accept()
            }

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
        audioInFlight = 0
        wasActive = true
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
                // The tap fires on the realtime audio thread; hop back to the
                // main actor before touching @Published state or the relay.
                engine.onChunk = { [weak self] chunk in
                    Task { @MainActor in self?.sendAudio(chunk) }
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
        // Three 100 ms packets in flight (~300 ms) is the ceiling; beyond that,
        // stale frames would only add delay.
        guard audioInFlight < 3, let send = sendPayload else { return }
        let packet = CallAudio(
            id: callId, peer: peerId, seq: seq, d: Base64URL.encode(data)
        )
        seq += 1
        guard let json = try? packet.toPayloadJSON() else { return }
        audioInFlight += 1
        sendPayload?(peerId, json, true, false) { [weak self] in
            self?.audioInFlight = max(0, (self?.audioInFlight ?? 1) - 1)
        }
    }

    private func send(_ signal: CallSignal, to peerId: String? = nil) {
        guard let json = try? signal.toPayloadJSON() else { return }
        let voip = signal.t == MessageType.callOffer.rawValue
        // A call offer is delivered by a PushKit VoIP push (CallKit screen);
        // every other signal stays silent and never produces a notification.
        sendPayload?(peerId ?? self.peerId, json, !voip, voip, nil)
    }

    private func finish(error: String? = nil) {
        let endedPeer = peerId
        let duration = seconds
        let outgoing = isOutgoing
        let missed = !wasActive
        let hadCall = !callId.isEmpty && !endedPeer.isEmpty
        timeoutTask?.cancel()
        timeoutTask = nil
        timer?.invalidate()
        timer = nil
        audio?.stop()
        audio = nil
        audioInFlight = 0
        onFastPolling?(false, nil)
        callId = ""
        seconds = 0
        muted = false
        speaker = false
        acceptWhenOffered = false
        self.error = error
        phase = .idle
        if hadCall {
            onCallEnded?(endedPeer, duration, outgoing, missed)
        }
        onCallFinished?()
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
