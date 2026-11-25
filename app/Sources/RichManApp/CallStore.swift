import SwiftUI
import Combine

/// Mock call state for the ported overlay. The real audio path (ADPCM 16 kHz,
/// jitter buffer, relay signalling) lands with the crypto/Tor wiring.
@MainActor
final class CallStore: ObservableObject {
    enum Phase: Equatable {
        case idle, incoming, active
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName = ""
    @Published private(set) var seconds = 0

    private var timer: Timer?

    init() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "rm.call") {
        case "incoming":
            peerName = "アリス"
            phase = .incoming
        case "active":
            peerName = "アリス"
            accept()
        default:
            break
        }
        #endif
    }

    func start(_ name: String) {
        peerName = name
        seconds = 0
        phase = .incoming
    }

    func accept() {
        phase = .active
        seconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .active else { return }
                self.seconds += 1
            }
        }
    }

    func decline() {
        end()
    }

    func end() {
        timer?.invalidate()
        timer = nil
        seconds = 0
        phase = .idle
    }
}
