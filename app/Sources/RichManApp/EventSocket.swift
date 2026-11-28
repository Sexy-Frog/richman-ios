import Foundation

/// Signal-style receive channel: one persistent WebSocket per app session.
/// The relay pushes a tiny "wake" when one of our receive mailboxes changes;
/// the app then fetches and decrypts over the normal HTTPS path. It carries no
/// message content and only runs in direct mode (Tor mode keeps polling).
@MainActor
final class EventSocket {
    private let url: URL
    private let onWake: () -> Void
    private var boxes: [String]
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Double = 2
    private var stopped = false

    init(url: URL, boxes: [String], onWake: @escaping () -> Void) {
        self.url = url
        self.boxes = boxes
        self.onWake = onWake
        connect()
    }

    /// Re-subscribe when contacts or invite mailboxes change.
    func update(boxes newBoxes: [String]) {
        guard newBoxes != boxes else { return }
        boxes = newBoxes
        reconnect()
    }

    func stop() {
        stopped = true
        retryTask?.cancel()
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        guard !stopped else { return }
        receiveTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        let payload = (try? JSONSerialization.data(
            withJSONObject: ["boxes": boxes]
        )) ?? Data("{\"boxes\":[]}".utf8)
        task.send(.data(payload)) { _ in }

        receiveLoop(task)
        pingLoop(task)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    if case .string(let text) = message {
                        if text == "wake" {
                            self?.onWake()
                        } else if text == "ready" {
                            self?.retryDelay = 2
                        }
                    }
                } catch {
                    break
                }
            }
            guard !Task.isCancelled else { return }
            self?.scheduleReconnect()
        }
    }

    private func pingLoop(_ task: URLSessionWebSocketTask) {
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                task.sendPing { _ in }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        retryTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func reconnect() {
        guard !stopped else { return }
        receiveTask?.cancel()
        pingTask?.cancel()
        connect()
    }
}
