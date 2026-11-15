import AVFoundation
import Combine
import CoreML
import CryptoKit
import os
import PerchCore

/// Neural voice separation for "Time words by ear" (off unless the user turns
/// it on). Before the speech recogniser hears the song, a neural network takes
/// the music out, so it hears the voice nearly alone.
///
/// The network is Spleeter 2stems by Deezer Research (MIT licence), converted
/// to Core ML by Scripts/make-vocal-model.sh. It is downloaded from Perch's
/// GitHub releases once, checked against the checksum below, compiled on this
/// Mac and kept in Application Support. It runs on this Mac only while Perch
/// listens; the sound never leaves it.
final class VocalSeparator: ObservableObject {
    static let shared = VocalSeparator()
    static let log = Logger(subsystem: "dev.perch.Perch", category: "separation")

    enum State: Equatable {
        case absent
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .absent {
        didSet { ready.withLock { $0 = state == .ready } }
    }
    /// `state == .ready`, readable from the listening thread.
    private let ready = OSAllocatedUnfairLock(initialState: false)

    /// The model Perch downloads, and what it must be.
    static let modelName = "Spleeter2Stems-1"
    static let modelURL = URL(string: "https://github.com/apathywoke/perch/releases/download/vocal-model-1/\(modelName).zip")!
    static let modelSHA256 = "7ddfa7a00f0a0924458c5392c231e56fa5329c9195e0ea09d3b073177c5d5607"
    static let modelBytes = 36_366_113

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/Models", isDirectory: true)
    }

    private static var compiled: URL { folder.appendingPathComponent(modelName + ".mlmodelc", isDirectory: true) }
    /// A download in progress, or a file put here by hand (Scripts/make-vocal-model.sh output).
    private static var archive: URL { folder.appendingPathComponent(modelName + ".zip") }

    /// Where the network runs; one stretch of sound at a time, never on the main thread.
    let queue = DispatchQueue(label: "dev.perch.Perch.separation", qos: .userInitiated)
    // Queue only:
    private var model: MLModel?
    private var sessions = 0
    private var unloadWork: DispatchWorkItem?

    private var progressTimer: Timer?

    init() {
        if FileManager.default.fileExists(atPath: Self.compiled.path) {
            state = .ready
            ready.withLock { $0 = true }
        }
    }

    static var wanted: Bool { Pref.bool(Pref.lyricsListenSeparate) }

    /// Whether new listening sessions hear the separated voice.
    var isActive: Bool { Self.wanted && ready.withLock { $0 } }

    // MARK: Installing

    /// Fetches, checks and compiles the model, unless it is here already.
    func install() {
        switch state {
        case .downloading, .preparing, .ready: return
        case .absent, .failed: break
        }
        state = .downloading(0)
        Task.detached(priority: .userInitiated) {
            do {
                try await self.fetchAndCompile()
                await MainActor.run {
                    self.stopProgress()
                    self.state = .ready
                }
                Self.log.notice("Voice separation model ready")
            } catch {
                Self.log.error("Voice separation model not installed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.stopProgress()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func fetchAndCompile() async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let archive = Self.archive
        if !manager.fileExists(atPath: archive.path) || (try? Self.checksum(of: archive)) != Self.modelSHA256 {
            try? manager.removeItem(at: archive)
            await MainActor.run { self.startProgress() }
            // curl blocks until done: keep it off Swift's few shared threads.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Network.download(Self.modelURL, to: archive, maxBytes: Self.modelBytes + 1_000_000, maxSeconds: 1800)
                    })
                }
            }
            guard try Self.checksum(of: archive) == Self.modelSHA256 else {
                try? manager.removeItem(at: archive)
                throw SeparationError.corrupt
            }
        }
        await MainActor.run {
            self.stopProgress()
            self.state = .preparing
        }
        let unpacked = manager.temporaryDirectory.appendingPathComponent("perch-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: unpacked) }
        try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let package = unpacked.appendingPathComponent("Spleeter2Stems.mlpackage", isDirectory: true)
        let compiledNow = try await MLModel.compileModel(at: package)
        defer { try? manager.removeItem(at: compiledNow) }
        _ = try MLModel(contentsOf: compiledNow) // make sure it loads before keeping it
        try? manager.removeItem(at: Self.compiled)
        try manager.moveItem(at: compiledNow, to: Self.compiled)
        try? manager.removeItem(at: archive)
    }

    /// Deletes the model; the option goes off with it.
    func delete() {
        guard state != .preparing, !isDownloading else { return }
        UserDefaults.standard.set(false, forKey: Pref.lyricsListenSeparate)
        queue.async {
            self.model = nil
            try? FileManager.default.removeItem(at: Self.folder)
        }
        state = .absent
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    /// Size of the model on this Mac, in bytes.
    func installedSize() -> Int64 {
        guard let items = FileManager.default.enumerator(at: Self.compiled, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// curl writes the file as it goes: its size is the progress.
    private func startProgress() {
        stopProgress()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, case .downloading = self.state else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: Self.archive.path)[.size] as? Int) ?? 0
            self.state = .downloading(min(1, Double(size) / Double(Self.modelBytes)))
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private static func checksum(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = [:]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SeparationError.tool(message) }
    }

    // MARK: Running (queue)

    /// The loaded network, kept while sessions use it and a little after.
    fileprivate func acquire() {
        unloadWork?.cancel()
        unloadWork = nil
        sessions += 1
    }

    fileprivate func release() {
        sessions -= 1
        guard sessions == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessions == 0 else { return }
            self.model = nil
        }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + 60, execute: work)
    }

    fileprivate func loadedModel() -> MLModel? {
        if let model { return model }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: Self.compiled, configuration: configuration)
            self.model = model
            return model
        } catch {
            Self.log.error("Voice separation model not loaded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Diagnostics

    func diagnosticRows() -> [(String, String)] {
        let text = switch state {
        case .absent: "not downloaded"
        case .downloading(let part): "downloading \(Int(part * 100))%"
        case .preparing: "preparing"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
        return [("Voice separation", Self.wanted ? "on, model \(text)" : "off, model \(text)")]
    }
}

enum SeparationError: LocalizedError {
    case corrupt
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .corrupt: NSLocalizedString("The downloaded model is damaged.", comment: "")
        case .tool(let message): message.isEmpty ? NSLocalizedString("The model could not be unpacked.", comment: "") : message
        }
    }
}

// MARK: - Sessions

/// What the listening engine feeds a stretch of the song to: the recogniser
/// itself, or the voice separation in front of it.
protocol ListeningSession: AnyObject {
    /// Where the next sound would land in the song.
    var expectedTime: Double? { get }
    func feed(_ buffer: AVAudioPCMBuffer, songTime: Double)
    func finish()
}

@available(macOS 26.0, *)
extension RecognitionSession: ListeningSession {}

@available(macOS 26.0, *)
extension VocalSeparator {
    /// The session to feed: the recogniser behind the voice separation when
    /// that is on and ready, or else the recogniser itself.
    func session(for recognition: RecognitionSession) -> ListeningSession {
        if Self.wanted, !ready.withLock({ $0 }) {
            // On, but the model is missing (say, Perch quit during the download): fetch it now.
            DispatchQueue.main.async { if self.state == .absent { self.install() } }
        }
        if Self.compare, ready.withLock({ $0 }) { return ComparingSession(recognition, separator: self) }
        return isActive ? SeparatedSession(recognition, separator: self) : recognition
    }

    /// `defaults write dev.perch.Perch compareSeparation -bool true` (with the model
    /// installed): two more recognisers hear each stretch, one the song as it is,
    /// one the separated voice, and the words each catches per minute are logged.
    static let compare = UserDefaults.standard.bool(forKey: "compareSeparation")
}

/// For measuring: the song goes to the recogniser as usual, and also to two
/// recognisers that only count words, with and without separation.
@available(macOS 26.0, *)
final class ComparingSession: ListeningSession {
    private let main: RecognitionSession
    private let plain: RecognitionSession
    private let separated: SeparatedSession
    private let plainWords = Tally()
    private let separatedWords = Tally()
    private static let totals = Totals()

    init(_ recognition: RecognitionSession, separator: VocalSeparator) {
        main = recognition
        let plainWords = plainWords, separatedWords = separatedWords
        plain = RecognitionSession(recognizer: recognition.recognizer, phrases: recognition.phrases) { words, _, _, _ in
            plainWords.add(words)
        }
        separated = SeparatedSession(RecognitionSession(recognizer: recognition.recognizer, phrases: recognition.phrases) { words, _, _, _ in
            separatedWords.add(words)
        }, separator: separator)
    }

    /// From the separation, which knows it from the first sound: a jump in the
    /// player's position then starts a new stretch for all three.
    var expectedTime: Double? { separated.expectedTime }

    func feed(_ buffer: AVAudioPCMBuffer, songTime: Double) {
        main.feed(buffer, songTime: songTime)
        plain.feed(buffer, songTime: songTime)
        separated.feed(buffer, songTime: songTime)
        separatedWords.begin(at: songTime)
        // The plain recogniser skips the sound that comes while it gets ready.
        if plain.expectedTime != nil { plainWords.begin(at: songTime) }
        plainWords.reach(songTime + Double(buffer.frameLength) / buffer.format.sampleRate)
    }

    func finish() {
        main.finish()
        plain.finish()
        separated.finish()
        // The last words come after the separation and the recognisers settle.
        let plainWords = plainWords, separatedWords = separatedWords
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            // Only the stretch both heard.
            guard let plainBegan = plainWords.began, let separatedBegan = separatedWords.began else { return }
            let from = max(plainBegan, separatedBegan)
            let to = plainWords.end
            guard to - from > 5 else { return }
            let plain = plainWords.count(from: from, to: to), separated = separatedWords.count(from: from, to: to)
            let (seconds, plainTotal, separatedTotal) = Self.totals.add(to - from, plain, separated)
            VocalSeparator.log.notice("Compare \(to - from, format: .fixed(precision: 0), privacy: .public) s: plain \(plain, privacy: .public) words, separated \(separated, privacy: .public). Total \(seconds, format: .fixed(precision: 0), privacy: .public) s: plain \(Double(plainTotal) * 60 / seconds, format: .fixed(precision: 1), privacy: .public)/min, separated \(Double(separatedTotal) * 60 / seconds, format: .fixed(precision: 1), privacy: .public)/min")
        }
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [Double] = []
        private(set) var began: Double?
        private(set) var end = -Double.infinity

        func add(_ words: [HeardWord]) {
            lock.withLock { starts += words.map(\.start) }
        }

        /// Where this recogniser started to listen.
        func begin(at time: Double) {
            lock.withLock { if began == nil { began = time } }
        }

        func reach(_ time: Double) { lock.withLock { end = max(end, time) } }

        func count(from: Double, to: Double) -> Int {
            lock.withLock { starts.filter { $0 >= from && $0 < to }.count }
        }
    }

    private final class Totals: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 0.0, plain = 0, separated = 0

        func add(_ seconds: Double, _ plain: Int, _ separated: Int) -> (Double, Int, Int) {
            lock.withLock {
                self.seconds += seconds
                self.plain += plain
                self.separated += separated
                return (self.seconds, self.plain, self.separated)
            }
        }
    }
}

/// Sound in from the player, the voice alone out to the recogniser, a few
/// seconds later. Each piece of voice goes out with the song time of the sound
/// it came from, so the recogniser's timing stays exact.
@available(macOS 26.0, *)
final class SeparatedSession: ListeningSession {
    private let recognition: RecognitionSession
    private let owner: VocalSeparator
    private let lock = NSLock()
    private var expected: Double?
    private var finished = false

    // Separation queue only:
    private let spectral: SpectralSeparator
    private var converter: AVAudioConverter?
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: SpectralSeparator.sampleRate, channels: 2)!
    private let mono = AVAudioFormat(standardFormatWithSampleRate: SpectralSeparator.sampleRate, channels: 1)!
    /// Song time at sample indices of the 44.1 kHz sound fed to the separator.
    private var anchors: [(index: Int, song: Double)] = []
    private var resampled = 0
    private var runs = 0
    /// Seconds spent separating, all of it and in the network alone (for the debug log).
    private var busy = 0.0
    private var network = 0.0
    private var warned = false

    init(_ recognition: RecognitionSession, separator owner: VocalSeparator) {
        self.recognition = recognition
        self.owner = owner
        spectral = SpectralSeparator(frames: 512, margin: 64)
        owner.queue.async { owner.acquire() }
    }

    var expectedTime: Double? {
        lock.withLock { expected }
    }

    /// Tap queue: the buffer is only valid now, so it is copied and handed on.
    func feed(_ buffer: AVAudioPCMBuffer, songTime: Double) {
        let proceed = lock.withLock {
            guard !finished else { return false }
            expected = songTime + Double(buffer.frameLength) / buffer.format.sampleRate
            return true
        }
        guard proceed, let copy = Self.copy(buffer) else { return }
        owner.queue.async { self.separate(copy, songTime: songTime) }
    }

    func finish() {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        owner.queue.async {
            let start = Date()
            let (samples, index) = self.spectral.flush(masker: self.mask)
            self.busy += Date().timeIntervalSince(start)
            self.deliver(samples, from: index)
            self.recognition.finish()
            if SongListener.debug, self.runs > 0 {
                let seconds = Double(self.resampled) / SpectralSeparator.sampleRate
                SongListener.log.notice("Separated \(seconds, format: .fixed(precision: 1), privacy: .public) s in \(self.runs, privacy: .public) runs, \(self.busy, format: .fixed(precision: 2), privacy: .public) s of work, \(self.network, format: .fixed(precision: 2), privacy: .public) s in the network")
            }
            self.owner.release()
        }
    }

    private func separate(_ buffer: AVAudioPCMBuffer, songTime: Double) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: stereo)
        }
        guard let converter, let converted = Self.convert(buffer, with: converter, to: stereo),
              let channels = converted.floatChannelData else { return }
        anchors.append((resampled, songTime))
        let count = Int(converted.frameLength)
        resampled += count
        let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let right = converted.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : left
        let start = Date()
        let (samples, index) = spectral.process(left: left, right: right, masker: mask)
        busy += Date().timeIntervalSince(start)
        deliver(samples, from: index)
    }

    /// The network's verdict on one stretch of spectrogram: how much of it is voice.
    private func mask(_ magnitudes: [Float]) -> [Float]? {
        guard let model = owner.loadedModel() else { return nil }
        let start = Date()
        let shape = [1, 2, spectral.frames, SpectralSeparator.bins] as [NSNumber]
        do {
            let input = try MLMultiArray(shape: shape, dataType: .float32)
            Self.write(magnitudes, to: input)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["magnitude": input]))
            guard let vocals = output.featureValue(for: "vocals")?.multiArrayValue,
                  let accompaniment = output.featureValue(for: "accompaniment")?.multiArrayValue else { return nil }
            let mask = SpectralSeparator.ratioMask(vocals: Self.read(vocals), accompaniment: Self.read(accompaniment))
            runs += 1
            network += Date().timeIntervalSince(start)
            return mask
        } catch {
            if !warned {
                warned = true
                VocalSeparator.log.error("Voice separation failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// Core ML's own conversions go element by element (about 100 ms a run); a
    /// densely packed float array is copied in one go instead.
    private static func write(_ values: [Float], to array: MLMultiArray) {
        guard array.dataType == .float32, isPacked(array) else {
            for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
            return
        }
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            values.withUnsafeBufferPointer { pointer.baseAddress!.update(from: $0.baseAddress!, count: min(values.count, pointer.count)) }
        }
    }

    private static func read(_ array: MLMultiArray) -> [Float] {
        guard array.dataType == .float32, isPacked(array) else { return MLShapedArray<Float>(converting: array).scalars }
        return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(array.count)) }
    }

    private static func isPacked(_ array: MLMultiArray) -> Bool {
        var expected = 1
        for (size, stride) in zip(array.shape.map(\.intValue), array.strides.map(\.intValue)).reversed() {
            if size > 1 && stride != expected { return false }
            expected *= size
        }
        return true
    }

    /// Hands the voice to the recogniser in short pieces, each with its song time.
    private func deliver(_ samples: [Float], from first: Int) {
        let piece = 8192
        var offset = 0
        while offset < samples.count {
            let count = min(piece, samples.count - offset)
            let index = first + offset
            while anchors.count > 1, anchors[1].index <= index { anchors.removeFirst() }
            guard let anchor = anchors.first,
                  let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(count)) else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }
            let songTime = anchor.song + Double(index - anchor.index) / SpectralSeparator.sampleRate
            recognition.feed(buffer, songTime: songTime)
            offset += count
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let data = from.mData, let destination = to.mData else { continue }
            memcpy(destination, data, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
