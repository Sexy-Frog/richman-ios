import Foundation
import AVFoundation
import RichManCore

/// Captures microphone audio, resamples to the negotiated voice rate, encodes
/// 300 ms IMA-ADPCM chunks and plays incoming chunks. Runs while a call is
/// active; the caller owns start/stop.
final class CallAudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let chunkSamples: Int
    private var converter: AVAudioConverter?

    private let lock = NSLock()
    private var pending: [Int16] = []
    private var muted = false
    private var queuedBuffers = 0
    private var running = false

    var onChunk: ((Data) -> Void)?

    init(rate: Int) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(rate),
            channels: 1,
            interleaved: true
        )!
        // 100 ms frames keep end-to-end latency close to Signal's while still
        // fitting comfortably in one encrypted relay envelope.
        self.chunkSamples = max(1, rate * 100 / 1000)
    }

    func start(speaker: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setPreferredSampleRate(format.sampleRate)
        try session.setActive(true)
        try? session.overrideOutputAudioPort(speaker ? .speaker : .none)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NSError(domain: "RichManCall", code: 1)
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            self?.capture(buffer)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        lock.lock()
        running = false
        pending.removeAll()
        lock.unlock()
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    func setMuted(_ value: Bool) {
        lock.lock()
        muted = value
        lock.unlock()
    }

    func setSpeaker(_ value: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(
            value ? .speaker : .none
        )
    }

    /// Schedule a decoded chunk. If the backlog is already deep (Tor bursts),
    /// newer packets are dropped rather than letting latency grow unbounded.
    func enqueue(_ data: Data) {
        let pcm = Adpcm.decode(data)
        guard !pcm.isEmpty else { return }
        lock.lock()
        let backlog = queuedBuffers
        lock.unlock()
        guard backlog < 6 else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pcm.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress,
                  let channel = buffer.int16ChannelData?[0] else { return }
            channel.update(from: base, count: pcm.count)
        }
        lock.lock()
        queuedBuffers += 1
        lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedBuffers = max(0, self.queuedBuffers - 1)
            self.lock.unlock()
        }
    }

    // MARK: capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData?[0] else { return }

        let samples = UnsafeBufferPointer(
            start: channel, count: Int(output.frameLength)
        )
        var chunks: [Data] = []
        lock.lock()
        let isMuted = muted
        pending.append(contentsOf: samples)
        while pending.count >= chunkSamples {
            let chunk = Array(pending.prefix(chunkSamples))
            pending.removeFirst(chunkSamples)
            if !isMuted { chunks.append(Adpcm.encode(chunk)) }
        }
        lock.unlock()

        for chunk in chunks { onChunk?(chunk) }
    }
}
