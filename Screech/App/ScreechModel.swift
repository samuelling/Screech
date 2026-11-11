import SwiftUI
import UIKit

struct ReceivedNote: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let mode: NoteMode
    let source: String              // "mic" or a file name
    let flags: Int
    let bytes: [UInt8]
    var status: NoteStatus
}

@MainActor
final class ScreechModel: ObservableObject {
    // shared
    @Published var passphrase = "" {
        didSet {
            if rememberPassphrase { Keychain.save(passphrase) }
            let box = passBox, rx = photoRx, pass = passphrase
            photoQueue.async { box.value = pass; let ps = rx.retry(); for p in ps { let s = ScreechModel.snapshot(p); Task { @MainActor in self.upsert(s) } } }
        }
    }
    @Published var rememberPassphrase = Keychain.load() != nil {
        didSet { if rememberPassphrase { Keychain.save(passphrase) } else { Keychain.delete() } }
    }
    @Published var status = "READY."
    // send
    @Published var message = ""
    @Published var mode: NoteMode = .sturdy
    @Published var intro = false
    @Published var sending = false
    // listen
    @Published var listening = false
    @Published var carrier = false
    @Published var receiveProgress: Double? = nil
    @Published var levelDb: Float = -90
    @Published var waterfall = Waterfall(bands: 48, rows: 90)
    @Published var received: [ReceivedNote] = []
    @Published var micDenied = false
    @Published var busyDecodingFile = false
    // photos
    enum SendKind: String, CaseIterable { case note = "NOTE", photo = "PHOTO" }
    @Published var sendKind: SendKind = .note
    @Published var photoSource: UIImage? = nil { didSet { prepPhoto() } }
    @Published var photoSize = "small" { didSet { prepPhoto() } }
    @Published var photoQuality = "medium" { didSet { prepPhoto() } }
    @Published var outgoing: OutgoingPhoto? = nil
    @Published var sendRevealRows: Int? = nil
    @Published var photos: [ReceivedPhoto] = []
    @Published var incomingPhotoFraction: Double? = nil
    private let photoQueue = DispatchQueue(label: "screech.photo")
    private let passBox: PassBox
    private let photoRx: PhotoReceiver
    private var revealTimer: Timer?
    private var incomingIsPhoto = false

    static let maxChars = 280
    private let audio = AudioIO()
    private var decoder: NoteDecoder?
    private var spectrum: SpectrumAnalyzer?
    private var ignoreUntil = Date.distantPast

    init() {
        let box = PassBox()
        passBox = box
        photoRx = PhotoReceiver(passphrase: { box.value })
        if let p = Keychain.load() { passphrase = p }
        audio.onInterrupted = { [weak self] in Task { @MainActor in self?.interrupted() } }
    }

    var airtime: Double {
        NoteModem.frameSeconds(bytes: NoteCrypto.estimateBytes(message, secret: !passphrase.isEmpty), mode: mode) + (intro ? NoteModem.introSeconds : 0)
    }

    // MARK: send
    func send() {
        guard !message.isEmpty, !sending else { return }
        let text = message, pass = passphrase, m = mode, intro = intro
        let audio = self.audio, rate = audio.playbackRate
        sending = true
        status = pass.isEmpty ? "SENDING OPEN NOTE…" : "ENCRYPTING…"
        Task.detached(priority: .userInitiated) {
            do {
                let (p, f) = try NoteCrypto.pack(text: text, passphrase: pass, modeId: m.id)
                let s = NoteSynth.render(payload: p, flags: f, mode: m, sampleRate: rate, amplitude: 0.7, intro: intro)
                await MainActor.run {
                    self.status = "SENDING \(m.name.uppercased()) · \(Int(Double(s.count) / rate + 0.5)) s"
                    self.ignoreUntil = Date().addingTimeInterval(Double(s.count) / rate + 0.6)
                }
                try audio.play(s) { Task { @MainActor in self.sendFinished() } }
            } catch {
                await MainActor.run { self.sending = false; self.status = "COULDN'T SEND: \(error.localizedDescription)" }
            }
        }
    }
    func stopSending() { audio.stopPlaying(); sendFinished(stopped: true) }
    private func sendFinished(stopped: Bool = false) {
        guard sending else { return }
        sending = false
        revealTimer?.invalidate(); revealTimer = nil; sendRevealRows = nil
        status = stopped ? "STOPPED." : "SENT."
        ignoreUntil = Date().addingTimeInterval(0.4)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// render the note to a .wav in the temporary folder, for the share sheet
    func noteFile() async throws -> URL {
        let text = message, pass = passphrase, m = mode, intro = intro
        return try await Task.detached(priority: .userInitiated) {
            let (p, f) = try NoteCrypto.pack(text: text, passphrase: pass, modeId: m.id)
            let s = NoteSynth.render(payload: p, flags: f, mode: m, sampleRate: 44100, amplitude: 0.7, intro: intro)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("screech-\(pass.isEmpty ? "open" : "secret")-note-\(df.string(from: Date())).wav")
            try NoteSynth.wav(s, sampleRate: 44100).write(to: url)
            return url
        }.value
    }

    // MARK: listen
    func toggleListening() { if listening { stopListening() } else { Task { await startListening() } } }

    func startListening() async {
        guard await AudioIO.requestMic() else { micDenied = true; status = "MICROPHONE ACCESS IS OFF."; return }
        micDenied = false
        do {
            audio.onInput = nil
            try audio.startListening()
            let rate = audio.inputRate
            let d = NoteDecoder(sampleRate: rate) { [weak self] e in Task { @MainActor in self?.handle(e) } }
            let sp = SpectrumAnalyzer(sampleRate: rate)
            decoder = d; spectrum = sp
            audio.onInput = { [weak self] x in
                d.push(x)
                let (rows, lvl) = sp.process(x)
                if !rows.isEmpty { Task { @MainActor in self?.addRows(rows, level: lvl) } }
            }
            listening = true
            status = "LISTENING… PLAY A NOTE NEAR THE MIC."
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            status = "COULDN'T LISTEN: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        audio.onInput = nil
        audio.stopListening()
        listening = false; carrier = false; receiveProgress = nil
        status = "STOPPED LISTENING."
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func interrupted() {
        listening = false; sending = false; carrier = false; receiveProgress = nil
        status = "AUDIO INTERRUPTED. TAP LISTEN TO RESUME."
    }

    private func addRows(_ rows: [[Float]], level: Float) {
        for r in rows { waterfall.push(r) }
        levelDb = level
    }

    private func handle(_ e: NoteEvent) {
        if Date() < ignoreUntil { return }       // don't decode our own note
        switch e {
        case .carrier(let on, _):
            carrier = on
            if !on { receiveProgress = nil; incomingPhotoFraction = nil }
        case .header(_, let version, _, let flags, _):
            incomingIsPhoto = version == NoteModem.photoFrameVersion
            if incomingIsPhoto { incomingPhotoFraction = 0; status = flags & 1 != 0 ? "RECEIVING A SECRET PHOTO…" : "RECEIVING A PHOTO…" }
            else { receiveProgress = 0; status = flags & NoteFlag.encrypted != 0 ? "RECEIVING A SECRET NOTE…" : "RECEIVING AN OPEN NOTE…" }
        case .progress(_, let f):
            if incomingIsPhoto { incomingPhotoFraction = f } else { receiveProgress = f }
        case .photo(let ok, let modeKey, let flags, let bytes):
            incomingPhotoFraction = nil
            if ok, let b = bytes { feedPhoto(b, flags: flags, mode: modeKey) }
            else { status = "A PHOTO STRIPE ARRIVED GARBLED. THE REST IS STILL COMING." }
        case .frame(let ok, let why, let modeKey, let flags, let bytes, _):
            receiveProgress = nil
            guard let m = NoteMode.byKey(modeKey) else { return }
            if ok, let b = bytes { accept(bytes: b, flags: flags, mode: m, source: "mic") }
            else if why == "crc" {
                status = "GARBLED NOTE. MOVE CLOSER, TURN THE VOLUME UP, OR TRY STURDY."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                announce("A note arrived too garbled to read.")
            }
        default: break
        }
    }

    private func accept(bytes: [UInt8], flags: Int, mode m: NoteMode, source: String) {
        let pass = passphrase
        status = flags & NoteFlag.encrypted != 0 ? "DECRYPTING…" : "NOTE RECEIVED."
        Task.detached(priority: .userInitiated) {
            let st = NoteCrypto.unpack(bytes, flags: flags, passphrase: pass, modeId: m.id)
            await MainActor.run {
                self.received.insert(ReceivedNote(date: Date(), mode: m, source: source, flags: flags, bytes: bytes, status: st), at: 0)
                self.status = Self.describe(st)
                UINotificationFeedbackGenerator().notificationOccurred(st == .wrongPassphrase ? .error : .success)
                self.announce(Self.spoken(st))
            }
        }
    }

    func retry(_ note: ReceivedNote) {
        let pass = passphrase
        Task.detached(priority: .userInitiated) {
            let st = NoteCrypto.unpack(note.bytes, flags: note.flags, passphrase: pass, modeId: note.mode.id)
            await MainActor.run {
                if let i = self.received.firstIndex(where: { $0.id == note.id }) { self.received[i].status = st }
                self.status = Self.describe(st)
                self.announce(Self.spoken(st))
            }
        }
    }

    func clearReceived() { received.removeAll() }

    // MARK: files
    func decodeFile(_ url: URL) {
        busyDecodingFile = true
        status = "DECODING \(url.lastPathComponent.uppercased())…"
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let (s, rate) = try AudioIO.readFile(url)
                let frames = NoteDecoder.decodeAll(s, sampleRate: rate)
                await MainActor.run {
                    self.busyDecodingFile = false
                    var found = false
                    for f in frames {
                        if case let .photo(true, k, flags, b?) = f { found = true; self.feedPhoto(b, flags: flags, mode: k) }
                        if case let .frame(true, _, k, flags, b?, _) = f, let m = NoteMode.byKey(k) {
                            found = true; self.accept(bytes: b, flags: flags, mode: m, source: url.lastPathComponent)
                        }
                    }
                    if !found {
                        let garbled = frames.contains { if case .frame(false, "crc", _, _, _, _) = $0 { return true }; return false }
                        self.status = garbled ? "THAT FILE HOLDS A NOTE, BUT IT'S TOO DAMAGED TO READ." : "NO NOTE FOUND IN THAT FILE."
                        self.announce(self.status)
                    }
                }
            } catch {
                await MainActor.run { self.busyDecodingFile = false; self.status = "COULDN'T OPEN THAT FILE." }
            }
        }
    }

    // MARK: photos
    var photoAirtime: Double {
        guard let o = outgoing else { return 0 }
        let enc = !passphrase.isEmpty
        var t = 2 * (NoteModem.frameSeconds(bytes: 11 + (enc ? 24 : 0), mode: mode) + PhotoCodec.gapSeconds)
        for b in o.encoded.bands { t += NoteModem.frameSeconds(bytes: 4 + b.count + (enc ? 16 : 0), mode: mode) + PhotoCodec.gapSeconds }
        return t + (intro ? NoteModem.introSeconds : 0)
    }

    private func prepPhoto() {
        guard let img = photoSource else { outgoing = nil; return }
        let L = PhotoCodec.sizes.first { $0.key == photoSize }?.longest ?? 96
        let q = PhotoCodec.qualities.first { $0.key == photoQuality }?.q ?? 35
        let pw = Int(img.size.width * img.scale), ph = Int(img.size.height * img.scale)
        Task.detached(priority: .userInitiated) {
            let (w, h) = PhotoCodec.fitSize(max(1, pw), max(1, ph), longest: L)
            let px = PixelImage.rgba(from: img, w: w, h: h)
            let enc = PhotoCodec.encode(rgba: px, w: w, h: h, quality: q)
            var out = [UInt8](repeating: 0, count: w * h * 4)
            for (i, b) in enc.bands.enumerated() { PhotoCodec.decodeBand(b, band: i, w: w, h: h, quality: q, gray: false, into: &out) }
            let prev = PixelImage.cgImage(rgba: out, w: w, h: h)
            await MainActor.run { self.outgoing = OutgoingPhoto(encoded: enc, preview: prev, bytes: enc.bands.reduce(0) { $0 + $1.count }) }
        }
    }

    func sendPhoto() {
        guard let o = outgoing, !sending else { return }
        let pass = passphrase, m = mode, intro = intro, audio = self.audio, rows = o.encoded.h
        sending = true; sendRevealRows = 0
        status = pass.isEmpty ? "SENDING PHOTO (NOT SECRET)…" : "ENCRYPTING PHOTO…"
        Task.detached(priority: .userInitiated) {
            do {
                let (_, frames) = try PhotoPacker.pack(o.encoded, passphrase: pass)
                let (s, marks) = PhotoPacker.render(frames, mode: m, sampleRate: AudioIO.playerRate, amplitude: 0.7, intro: intro)
                let dur = Double(s.count) / AudioIO.playerRate
                await MainActor.run {
                    self.status = "SENDING PHOTO · \(m.name.uppercased()) · \(Int(dur + 0.5)) S"
                    self.ignoreUntil = Date().addingTimeInterval(dur + 0.6)
                    self.startReveal(marks: marks, rows: rows)
                }
                try audio.play(s) { Task { @MainActor in self.sendFinished() } }
            } catch {
                await MainActor.run { self.sending = false; self.sendRevealRows = nil; self.status = "COULDN'T SEND: \(error.localizedDescription)" }
            }
        }
    }

    /// the sender's own preview paints in, stripe by stripe, in time with the sound
    private func startReveal(marks: [(start: Double, end: Double, index: Int)], rows: Int) {
        revealTimer?.invalidate()
        let t0 = Date()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sending else { return }
                let t = Date().timeIntervalSince(t0)
                var r = 0
                for mk in marks where mk.index >= 0 {
                    if t >= mk.end { r = (mk.index + 1) * 16 } else if t > mk.start { r = mk.index * 16 + Int(16 * (t - mk.start) / (mk.end - mk.start)) }
                }
                self.sendRevealRows = min(rows, r)
            }
        }
    }

    func photoFile() async throws -> URL {
        guard let o = outgoing else { throw NSError(domain: "Screech", code: 4) }
        let pass = passphrase, m = mode, intro = intro
        return try await Task.detached(priority: .userInitiated) {
            let (_, frames) = try PhotoPacker.pack(o.encoded, passphrase: pass)
            let (s, _) = PhotoPacker.render(frames, mode: m, sampleRate: 44100, amplitude: 0.7, intro: intro)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("screech-\(pass.isEmpty ? "open" : "secret")-photo-\(df.string(from: Date())).wav")
            try NoteSynth.wav(s, sampleRate: 44100).write(to: url)
            return url
        }.value
    }

    private func feedPhoto(_ b: [UInt8], flags: Int, mode: String) {
        let rx = photoRx
        photoQueue.async {
            guard let p = rx.feed(b, flags: flags, mode: mode) else { return }
            let s = ScreechModel.snapshot(p)
            Task { @MainActor in self.upsert(s) }
        }
    }

    nonisolated static func snapshot(_ p: PhotoReceiver.Photo) -> ReceivedPhoto {
        var r = ReceivedPhoto(id: p.id)
        r.mode = p.mode; r.w = p.w; r.h = p.h; r.bands = p.bands; r.got = p.got.count; r.lost = p.lost.sorted(); r.next = p.next
        r.status = p.status; r.encrypted = p.encrypted
        r.image = (p.status == .locked || p.status == .wrongPassphrase) ? nil : PixelImage.cgImage(rgba: p.rgba, w: p.w, h: p.h)
        return r
    }

    private func upsert(_ s: ReceivedPhoto) {
        var s = s
        if let i = photos.firstIndex(where: { $0.id == s.id }) {
            let was = photos[i].status
            s.date = photos[i].date; photos[i] = s
            if was != .done && s.status == .done { photoDone(s) }
        } else {
            photos.insert(s, at: 0)
            if s.status == .done { photoDone(s) }
        }
        switch s.status {
        case .locked: status = "🔒 SECRET PHOTO. ENTER THE PASSPHRASE TO SEE IT."
        case .wrongPassphrase: status = "✗ WRONG PASSPHRASE FOR THAT PHOTO."
        case .receiving: status = "RECEIVING PHOTO… STRIPE \(min(s.bands, s.next + 1)) OF \(s.bands)"
        default: break
        }
    }
    private func photoDone(_ s: ReceivedPhoto) {
        status = s.lost.isEmpty ? (s.encrypted ? "✓ SECRET PHOTO RECEIVED" : "PHOTO RECEIVED (NOT SECRET)") : "PHOTO RECEIVED WITH \(s.lost.count) DAMAGED STRIPE\(s.lost.count == 1 ? "" : "S")"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        announce(status)
    }
    func clearPhotos() { photos.removeAll() }

    // MARK: text
    static func describe(_ s: NoteStatus) -> String {
        switch s {
        case .secret: return "✓ SECRET NOTE (PASSPHRASE MATCHED)"
        case .open: return "OPEN NOTE RECEIVED (NOT SECRET)"
        case .locked: return "🔒 SECRET NOTE. ENTER THE PASSPHRASE TO READ IT."
        case .wrongPassphrase: return "✗ WRONG PASSPHRASE."
        case .garbled: return "GARBLED NOTE."
        }
    }
    static func spoken(_ s: NoteStatus) -> String {
        switch s {
        case .secret(let t): return "Secret note: \(t)"
        case .open(let t): return "Open note: \(t)"
        case .locked: return "A secret note arrived. Enter the passphrase to read it."
        case .wrongPassphrase: return "A secret note arrived, but the passphrase doesn't match."
        case .garbled: return "A note arrived too garbled to read."
        }
    }
    private func announce(_ s: String) { UIAccessibility.post(notification: .announcement, argument: s) }
}

/// rolling spectrogram, newest row at the bottom
struct Waterfall: Equatable {
    let bands: Int, rows: Int
    var pixels: [UInt8]                 // RGBA, rows × bands
    init(bands: Int, rows: Int) { self.bands = bands; self.rows = rows; pixels = [UInt8](repeating: 0, count: bands * rows * 4); for i in 0..<(bands * rows) { pixels[i * 4 + 3] = 255 } }
    mutating func push(_ row: [Float]) {
        pixels.removeFirst(bands * 4)
        for v in row.prefix(bands) {
            let x = Double(v)
            // phosphor ramp: black → deep green → bright green → white-hot
            let g = UInt8(min(255, x * 1.5 * 255)), r = UInt8(max(0, min(255, (x - 0.65) * 3 * 255))), b = UInt8(max(0, min(255, (x - 0.5) * 2 * 160)))
            pixels += [r, g, b, 255]
        }
        if row.count < bands { pixels += [UInt8](repeating: 0, count: (bands - row.count) * 4) }
    }
    var image: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: bands, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bands * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum Keychain {
    static let service = "com.samuelling.screech", account = "passphrase"
    static func save(_ s: String) {
        delete()
        guard !s.isEmpty else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecValueData as String: Data(s.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
