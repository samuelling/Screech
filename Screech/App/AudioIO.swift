import AVFoundation

/// Owns the audio session and engine. Not tied to the UI: it delivers callbacks on its own queue and the
/// model hops to the main actor. The session uses .measurement mode, which turns off the iPhone's voice
/// processing (echo cancelling, noise suppression, automatic gain) so the tones arrive as they were played.
final class AudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "screech.audio")
    private var tapped = false
    private var playerConnected = false

    /// called on the audio queue with mono input samples at `inputRate`
    var onInput: (([Float]) -> Void)?
    private(set) var inputRate: Double = 48000

    init() {
        engine.attach(player)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    var onInterrupted: (() -> Void)?
    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        stopListening()
        player.stop()
        onInterrupted?()
    }

    static func requestMic() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try s.setActive(true)
    }

    /// notes are rendered at this rate; the mixer converts to whatever the hardware runs at
    static let playerRate = 48000.0
    private let playerFormat = AVAudioFormat(standardFormatWithSampleRate: AudioIO.playerRate, channels: 1)!

    private func connectPlayerIfNeeded() {
        guard !playerConnected else { return }
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        playerConnected = true
    }

    private func startEngine() throws {
        connectPlayerIfNeeded()
        if !engine.isRunning { engine.prepare(); try engine.start() }
    }

    func startListening() throws {
        try configureSession()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw NSError(domain: "Screech", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."]) }
        inputRate = fmt.sampleRate
        if !tapped {
            input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
                guard let self, let ch = buf.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
                self.queue.async { self.onInput?(samples) }
            }
            tapped = true
        }
        try startEngine()
    }

    func stopListening() {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        if !player.isPlaying && engine.isRunning { engine.stop() }
    }

    /// play mono samples (rendered at `outputRate`); `done` is called when playback finishes or is stopped
    func play(_ samples: [Float], done: @escaping () -> Void) throws {
        try configureSession()
        try startEngine()
        guard let buf = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData?[0] else { throw NSError(domain: "Screech", code: 2) }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: samples.count) }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in done() }
        player.play()
    }

    func stopPlaying() { player.stop() }

    /// the rate notes should be rendered at (the player's connection format)
    var playbackRate: Double { AudioIO.playerRate }

    /// read any audio file the system can open, mixed down to mono
    static func readFile(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { throw NSError(domain: "Screech", code: 3) }
        try f.read(into: buf)
        let n = Int(buf.frameLength), chans = Int(fmt.channelCount)
        var out = [Float](repeating: 0, count: n)
        if let data = buf.floatChannelData {
            for c in 0..<chans { let p = data[c]; for i in 0..<n { out[i] += p[i] / Float(chans) } }
        }
        return (out, fmt.sampleRate)
    }
}
