import Foundation
import UIKit
import AVFoundation
import CallKit
import PushKit
import UserNotifications

/// PushKit + CallKit integration.
///
/// A content-free VoIP push (the destination mailbox only) wakes the app even
/// after it was terminated, reports a native incoming call immediately, and
/// then the encrypted offer is fetched over the normal relay path. The relay
/// never sees the caller or the offer. Typing/read/call-control signals remain
/// silent; only a call offer produces this ring.
@MainActor
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private var provider: CXProvider?
    private var registry: PKPushRegistry?
    private var callUUID = UUID()
    private var activeSystemCall = false
    private var generation = 0
    private var started = false

    var isRinging: Bool { activeSystemCall }

    func start() {
        guard !started else { return }
        started = true

        let config = CXProviderConfiguration(localizedName: "RichMan")
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        let provider = CXProvider(configuration: config)
        provider.setDelegate(self, queue: .main)
        self.provider = provider

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// Update the native call screen with the decrypted display name.
    func updateCaller(name: String) {
        guard activeSystemCall, let provider else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: trimmed)
        update.localizedCallerName = trimmed
        update.hasVideo = false
        provider.reportCall(with: callUUID, updated: update)
    }

    /// Called by CallStore after the call is torn down.
    func callEnded() {
        generation += 1
        AppServices.shared.calls?.setUsesSystemUI(false)
        guard activeSystemCall else { return }
        activeSystemCall = false
        provider?.reportCall(
            with: callUUID,
            endedAt: Date(),
            reason: .remoteEnded
        )
    }

    // MARK: incoming

    private func reportIncoming(box: String?) {
        // Apple requires every VoIP push to result in a CallKit report. If a
        // call is already ringing, re-report the same call (and let CallStore
        // answer "busy" to the second offer) instead of silently dropping it.
        if activeSystemCall {
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "RichMan")
            update.localizedCallerName = "RichMan"
            provider?.reportNewIncomingCall(with: callUUID, update: update) { _ in }
            Task { @MainActor in
                await AppServices.shared.handleVoIPCall(box: box)
            }
            return
        }
        guard let provider, let calls = AppServices.shared.calls else { return }

        callUUID = UUID()
        generation += 1
        let thisGeneration = generation

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "RichMan")
        update.localizedCallerName = "RichMan"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        activeSystemCall = true
        calls.setUsesSystemUI(true)

        provider.reportNewIncomingCall(with: callUUID, update: update) {
            [weak self] error in
            guard let self else { return }
            if error != nil {
                DispatchQueue.main.async {
                    self.activeSystemCall = false
                    calls.setUsesSystemUI(false)
                }
                return
            }
            // Fetch the encrypted offer so the caller name and signalling are
            // available before the user answers.
            Task { @MainActor in
                await AppServices.shared.handleVoIPCall(box: box)
            }
        }

        // If the relay/network never delivers the offer, do not leave the
        // native call screen ringing forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self,
                  self.generation == thisGeneration,
                  self.activeSystemCall else { return }
            if calls.phase == .idle || calls.phase == .ended {
                calls.endFromSystem()
            }
        }
    }
}

// MARK: - PushKit

extension CallKitManager: PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate credentials: PKPushCredentials,
        for type: PKPushType
    ) {
        let token = credentials.token
            .map { String(format: "%02x", $0) }
            .joined()
        UserDefaults.standard.set(token, forKey: "rm.voipToken")
        NotificationCenter.default.post(name: .rmVoIPToken, object: token)
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        UserDefaults.standard.removeObject(forKey: "rm.voipToken")
        NotificationCenter.default.post(name: .rmVoIPToken, object: "")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Every VoIP push must be reported to CallKit immediately.
        let box = payload.dictionaryPayload["box"] as? String
        reportIncoming(box: box)
        completion()
    }
}

// MARK: - CallKit

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeSystemCall = false
        AppServices.shared.calls?.setUsesSystemUI(false)
        AppServices.shared.calls?.endFromSystem()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        AppServices.shared.calls?.acceptFromSystem()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        AppServices.shared.calls?.endFromSystem()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        AppServices.shared.calls?.setMutedFromSystem(action.isMuted)
        action.fulfill()
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXSetHeldCallAction
    ) {
        action.fulfill()
    }

    func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        // CallKit owns activation; make sure the voice route is configured
        // before CallAudioEngine starts.
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth]
        )
    }
}

extension Notification.Name {
    static let rmVoIPToken = Notification.Name("rm.voipToken")
}
