import AppKit
import AVFoundation
import Combine
import CoreAudio
import CryptoKit
import NaturalLanguage
import os
import PerchCore
import Speech

/// Times the lyrics word by word from the song itself (an experiment, off
/// unless the user turns it on). Perch takes the sound of the playing app as
/// it goes to the speakers, recognises the sung words on this Mac with the
/// system speech recogniser, and fits the lyrics to them. Nothing leaves the
/// Mac; what was heard is kept per song, so the next listen is timed from the start.
final class SongListener: ObservableObject {
    static let shared = SongListener()
    static let log = Logger(subsystem: "dev.perch.Perch", category: "listening")

    enum Status: Equatable {
        case off
        case needsNewerSystem
        case waiting
        case unsupportedLanguage(String)
        case preparing
        case listening
        /// The whole song was heard before; nothing more to listen for.
        case learned
        case noSound
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    /// Words heard in the current song and how many of the lyrics they timed.
    @Published private(set) var heardWords = 0
    @Published private(set) var timedWords = 0
    @Published private(set) var totalWords = 0

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private var cancellables: Set<AnyCancellable> = []
    private var song: String?
    private var transcript = HeardTranscript()
    private var dirty = false
    private var retimeScheduled = false
    private var saveTimer: Timer?
    private var engine: AnyObject? // ListeningEngine on macOS 26
    private var engineKey: String?
    private var languages: [String: Recognizer?] = [:]

    /// Which system recogniser hears the song: the dictation model, which knows
    /// more languages and times words better, or else the newer speech model.
    struct Recognizer: Equatable {
        let locale: Locale
        let dictation: Bool
    }

    func start() {
        MediaService.shared.$track
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.save() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.save() }
        evaluate()
    }

    /// `defaults write dev.perch.Perch debugListening -bool true` logs what is heard, for tuning.
    static let debug = UserDefaults.standard.bool(forKey: "debugListening")

    static var enabled: Bool {
        Pref.bool(Pref.lyricsEnabled) && Pref.bool(Pref.lyricsListen)
    }

    /// LyricsService loaded new lyrics: apply what was heard of this song before.
    func lyricsLoaded(for track: Track) {
        guard Self.enabled else { return }
        switchSong(to: track.id)
        retimeNow()
        evaluate()
    }

    // MARK: Deciding

    private func evaluate() {
        guard Self.enabled else {
            stopEngine()
            if status != .off { status = .off }
            return
        }
        guard Self.isSupported else {
            status = .needsNewerSystem
            return
        }
        let track = MediaService.shared.track
        if let track { switchSong(to: track.id) }
        guard let track, let bundleId = track.bundleId,
              let lines = LyricsService.shared.baseLines(for: track.id),
              !lines.allSatisfy({ $0.wordSynced || $0.text.isEmpty }) else {
            stopEngine()
            if case .failed = status {} else { status = .waiting }
            return
        }
        if let first = lines.first(where: { !$0.text.isEmpty })?.time, let last = lines.last?.time,
           transcript.coverage(from: first, to: last + 3) >= 0.9 {
            stopEngine()
            status = .learned
            return
        }
        guard let recognizer = language(of: track.id, lines: lines) else {
            stopEngine()
            if case .unsupportedLanguage = status {} else {
                status = .unsupportedLanguage(Self.languageName(lines))
            }
            return
        }
        if #available(macOS 26.0, *) {
            let key = "\(bundleId)\u{1}\(recognizer.locale.identifier)\u{1}\(recognizer.dictation)"
            if let engine = engine as? ListeningEngine, engineKey == key {
                engine.update(track)
                return
            }
            if case .failed = status, engineKey == key { return } // don't retry in a loop
            stopEngine()
            engineKey = key
            status = .preparing
            let engine = ListeningEngine(bundleId: bundleId, recognizer: recognizer, track: track) { [weak self] event in
                self?.handle(event)
            }
            self.engine = engine
            engine.start()
        }
    }

    private func stopEngine() {
        guard engine != nil else { return }
        if #available(macOS 26.0, *) { (engine as? ListeningEngine)?.stop() }
        engine = nil
        engineKey = nil
        save()
    }

    /// The language of the lyrics, if the recogniser knows it; checked once per song.
    private func language(of id: String, lines: [LyricLine]) -> Recognizer? {
        if let known = languages[id] { return known }
        guard #available(macOS 26.0, *) else { return nil }
        languages[id] = .some(nil)
        let text = lines.map(\.text).joined(separator: "\n")
        Task { @MainActor in
            let speech = await SpeechTranscriber.supportedLocales
            let dictation = await DictationTranscriber.supportedLocales
            // Lyrics mix languages and slang, so an open guess can be odd (Kazakh or
            // Bulgarian for Russian rap): only languages a recogniser knows may win.
            let detector = NLLanguageRecognizer()
            detector.languageConstraints = Array(Set((speech + dictation).compactMap { $0.language.languageCode?.identifier })
                .map(NLLanguage.init(rawValue:)))
            detector.processString(text)
            let candidates = detector.languageHypotheses(withMaximum: 3)
                .sorted { $0.value > $1.value }
                .map(\.key)
            // supportedLocale(equivalentTo:) answers even for languages a model lacks; check the list too.
            func listed(_ locale: Locale?, in list: [Locale]) -> Locale? {
                guard let locale else { return nil }
                let tag = locale.identifier(.bcp47)
                return list.contains { $0.identifier(.bcp47) == tag } ? locale : nil
            }
            var choice: Recognizer?
            for language in candidates where choice == nil {
                let wanted = Locale(identifier: language.rawValue)
                // Dictation first: it times the start of each word well, while the
                // newer model often starts a word where the one before ended.
                if let locale = listed(await DictationTranscriber.supportedLocale(equivalentTo: wanted), in: dictation) {
                    choice = Recognizer(locale: locale, dictation: true)
                } else if let locale = listed(await SpeechTranscriber.supportedLocale(equivalentTo: wanted), in: speech) {
                    choice = Recognizer(locale: locale, dictation: false)
                }
            }
            self.languages[id] = .some(choice)
            let described = choice.map { "\($0.locale.identifier) (\($0.dictation ? "dictation" : "speech") model)" } ?? "not supported"
            let guesses = candidates.map(\.rawValue).joined(separator: ", ")
            Self.log.notice("Lyrics language \(guesses, privacy: .public): \(described, privacy: .public)")
            if choice != nil { self.status = .preparing }
            self.evaluate()
        }
        return nil
    }

    private static func languageName(_ lines: [LyricLine]) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.map(\.text).joined(separator: "\n"))
        guard let code = recognizer.dominantLanguage?.rawValue else { return "?" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: Results

    enum Event {
        case listening
        case heard(words: [HeardWord], from: Double, to: Double, listened: Double)
        case noSound
        case failed(String)
    }

    private func handle(_ event: Event) {
        switch event {
        case .listening:
            if status != .listening { status = .listening }
        case .noSound:
            status = .noSound
        case .failed(let message):
            Self.log.error("Listening failed: \(message, privacy: .public)")
            status = .failed(message)
            if #available(macOS 26.0, *) { (engine as? ListeningEngine)?.stop() }
            engine = nil
        case .heard(let words, let from, let to, let listened):
            guard song == MediaService.shared.track?.id else { return }
            if status != .listening { status = .listening }
            transcript.replace(from: from, to: to, with: words)
            transcript.listen(from: listened, to: to)
            dirty = true
            scheduleRetime()
        }
    }

    private func switchSong(to id: String) {
        guard id != song else { return }
        save()
        song = id
        transcript = HeardStore.load(id) ?? HeardTranscript()
        dirty = false
        heardWords = transcript.words.count
    }

    private func scheduleRetime() {
        guard !retimeScheduled else { return }
        retimeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.retimeScheduled = false
            self?.retimeNow()
        }
    }

    private func retimeNow() {
        guard let song else { return }
        let lines = LyricsService.shared.retime(transcript.words, for: song)
        heardWords = transcript.words.count
        if let lines {
            timedWords = lines.map(\.heard).reduce(0, +)
            totalWords = lines.filter { !$0.text.isEmpty }.map(\.words.count).reduce(0, +)
            if Self.debug, let base = LyricsService.shared.baseLines(for: song) {
                let moves = zip(base, lines).filter { !$0.0.text.isEmpty }
                    .map { String(format: "%+.2f%@", $0.1.time - $0.0.time, $0.1.heard > 0 ? "*" : "") }
                Self.log.notice("Timed \(self.timedWords, privacy: .public)/\(self.totalWords, privacy: .public) words from \(self.transcript.words.count, privacy: .public) heard; line moves: \(moves.joined(separator: " "), privacy: .public)")
            }
        }
    }

    private func save() {
        guard dirty, let song else { return }
        dirty = false
        HeardStore.save(transcript, for: song)
    }

    /// Forgets everything heard, in every song.
    func forgetAll() {
        transcript = HeardTranscript()
        dirty = false
        HeardStore.clear()
        if let song { _ = LyricsService.shared.retime([], for: song) }
        heardWords = 0
        timedWords = 0
    }

    func diagnosticRows() -> [(String, String)] {
        let state = switch status {
        case .off: "off"
        case .needsNewerSystem: "needs macOS 26"
        case .waiting: "waiting for synced lyrics"
        case .unsupportedLanguage(let name): "language not supported (\(name))"
        case .preparing: "preparing"
        case .listening: "listening"
        case .learned: "song already heard"
        case .noSound: "no sound received"
        case .failed(let message): "failed: \(message)"
        }
        return [
            ("Listening", state),
            ("Words heard in this song", "\(heardWords)"),
            ("Lyric words timed by ear", "\(timedWords) of \(totalWords)"),
            ("Songs remembered", "\(HeardStore.count())"),
        ]
    }
}

// MARK: - Storage

/// What was heard of each song, in Application Support, never sent anywhere.
/// Files are named by a hash of the song, so the folder shows no titles.
enum HeardStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/Heard", isDirectory: true)
    }

    private static func file(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".json")
    }

    static func load(_ id: String) -> HeardTranscript? {
        guard let data = try? Data(contentsOf: file(for: id)) else { return nil }
        return try? JSONDecoder().decode(HeardTranscript.self, from: data)
    }

    static func save(_ transcript: HeardTranscript, for id: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(transcript).write(to: file(for: id), options: .atomic)
        } catch {
            SongListener.log.error("Could not save heard words: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }.count) ?? 0
    }
}

// MARK: - Engine

/// The sound of one app, cut into recognition sessions that each cover a
/// stretch of uninterrupted playback; a pause or a seek starts a new one.
@available(macOS 26.0, *)
final class ListeningEngine {
    private let bundleId: String
    private let recognizer: SongListener.Recognizer
    private let report: (SongListener.Event) -> Void
    private let tap = AudioTap()
    private let lock = NSLock()
    private var track: Track
    private var session: RecognitionSession?
    private var latency: Double = 0
    private var shift: Double = 0
    private var stopped = false
    private var heardSound = false
    private var silentSeconds = 0.0

    init(bundleId: String, recognizer: SongListener.Recognizer, track: Track,
         report: @escaping (SongListener.Event) -> Void) {
        self.bundleId = bundleId
        self.recognizer = recognizer
        self.track = track
        self.report = report
        self.shift = LyricsClock.shift(for: track) + Pref.double(Pref.lyricsDelay)
    }

    func start() {
        let recognizer = recognizer
        Task {
            do {
                try await RecognitionSession.installAssets(for: recognizer)
            } catch {
                await MainActor.run { self.report(.failed(NSLocalizedString("The speech model could not be installed.", comment: ""))) }
                return
            }
            await MainActor.run { self.startTap() }
        }
    }

    private func startTap() {
        guard !stopped else { return }
        latency = AudioTap.outputLatency()
        do {
            try tap.start(bundleId: bundleId) { [weak self] buffer, hostTime in
                self?.received(buffer, hostTime: hostTime)
            }
            SongListener.log.notice("Listening to \(self.bundleId, privacy: .public), output latency \(self.latency, privacy: .public) s")
        } catch {
            report(.failed(error.localizedDescription))
        }
    }

    /// New playback state from the player (main thread).
    func update(_ track: Track) {
        lock.lock()
        self.track = track
        // The lyrics' own timeline: the player's position with Perch's usual correction,
        // but without the user's (that one applies when showing).
        shift = LyricsClock.shift(for: track) + Pref.double(Pref.lyricsDelay)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let session = self.session
        self.session = nil
        lock.unlock()
        tap.stop()
        session?.finish()
    }

    /// A buffer of sound (tap queue).
    private func received(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        noteLoudness(buffer, seconds: seconds)
        guard track.isPlaying else {
            session?.finish()
            session = nil
            return
        }
        let when = AudioTap.date(forHostTime: hostTime).addingTimeInterval(latency)
        let songTime = track.position(at: when) + shift
        if let current = session, let expected = current.expectedTime, abs(expected - songTime) > 2.5 {
            // Seeked or skipped: what follows is a different stretch of the song.
            // (Smaller jumps are the player correcting its position; the session follows them.)
            current.finish()
            session = nil
        }
        if session == nil {
            let report = self.report
            session = RecognitionSession(recognizer: recognizer) { words, from, to, listened in
                DispatchQueue.main.async { report(.heard(words: words, from: from, to: to, listened: listened)) }
            }
            DispatchQueue.main.async { report(.listening) }
        }
        session?.feed(buffer, songTime: songTime)
    }

    /// Zeros only, for a while, mean macOS is not letting the sound through.
    private func noteLoudness(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        guard !heardSound, let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for index in stride(from: 0, to: count, by: 8) where samples[index] != 0 {
                heardSound = true
                return
            }
        }
        guard track.isPlaying else { return }
        silentSeconds += seconds
        if silentSeconds > 8 {
            silentSeconds = -.infinity
            let report = self.report
            DispatchQueue.main.async { report(.noSound) }
        }
    }
}

/// One run of the system speech recogniser over a stretch of the song.
@available(macOS 26.0, *)
final class RecognitionSession {
    /// Words of a final result, the stretch they cover, and where this session's listening began.
    typealias Output = (_ words: [HeardWord], _ from: Double, _ to: Double, _ listenedFrom: Double) -> Void

    private let lock = NSLock()
    private let output: Output
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    /// How much sound the recogniser has been given, in seconds, and where in
    /// the song it was at moments along the way: the player's position is
    /// followed whenever it corrects itself.
    private var fed = 0.0
    private var anchors: [(fed: Double, song: Double)] = []
    private var finished = false

    static func installAssets(for recognizer: SongListener.Recognizer) async throws {
        let module = makeModule(recognizer, live: false)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            SongListener.log.notice("Installing the speech model for \(recognizer.locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
    }

    private static func makeModule(_ recognizer: SongListener.Recognizer, live: Bool) -> any SpeechModule {
        if recognizer.dictation {
            return DictationTranscriber(locale: recognizer.locale, contentHints: [], transcriptionOptions: [],
                                        reportingOptions: live ? [.volatileResults, .frequentFinalization] : [],
                                        attributeOptions: [.audioTimeRange])
        }
        return SpeechTranscriber(locale: recognizer.locale, transcriptionOptions: [],
                                 reportingOptions: live ? [.volatileResults] : [],
                                 attributeOptions: [.audioTimeRange])
    }

    init(recognizer: SongListener.Recognizer, output: @escaping Output) {
        self.output = output
        Task { await prepare(recognizer) }
    }

    /// Where the next sound would land in the song, while the session is running.
    var expectedTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return anchors.last.map { $0.song + fed - $0.fed }
    }

    /// Song time of a moment in the recogniser's timeline.
    private func songTime(at time: Double) -> Double {
        let anchor = anchors.last { $0.fed <= time } ?? anchors.first ?? (0, 0)
        return anchor.song + time - anchor.fed
    }

    private func prepare(_ recognizer: SongListener.Recognizer) async {
        let module = Self.makeModule(recognizer, live: true)
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return }
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            SongListener.log.error("Recogniser not ready: \(error.localizedDescription, privacy: .public)")
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let proceed = lock.withLock {
            guard !finished else { return false }
            self.analyzer = analyzer
            self.format = format
            self.input = continuation
            return true
        }
        guard proceed else { return }

        // Holds the session until the recogniser is done: its last, final words
        // arrive after the session has been let go.
        resultsTask = Task { [self] in
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await result in transcriber.results {
                        self.deliver(result.text, result.range, final: result.range.end <= result.resultsFinalizationTime)
                    }
                } else if let transcriber = module as? DictationTranscriber {
                    for try await result in transcriber.results {
                        self.deliver(result.text, result.range, final: result.range.end <= result.resultsFinalizationTime)
                    }
                }
            } catch {
                SongListener.log.error("Recognition stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            SongListener.log.error("Recogniser did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer, songTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let format, let input else { return } // still preparing: this sound is skipped
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter, let converted = Self.convert(buffer, with: converter, to: format) else { return }
        if let last = anchors.last {
            let drift = songTime - (last.song + fed - last.fed)
            if abs(drift) > 0.25 {
                anchors.append((fed, songTime))
                if SongListener.debug { SongListener.log.notice("Position corrected by \(drift, format: .fixed(precision: 2), privacy: .public) s") }
            }
        } else {
            anchors.append((0, songTime))
            if SongListener.debug { SongListener.log.notice("Session starts at \(songTime, format: .fixed(precision: 2), privacy: .public)") }
        }
        fed += Double(buffer.frameLength) / buffer.format.sampleRate
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() {
        lock.lock()
        finished = true
        let input = self.input
        let analyzer = self.analyzer
        self.input = nil
        lock.unlock()
        input?.finish()
        // Let the recogniser settle what it heard last, then let go.
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
    }

    /// Only final results time each word; the ones before give a single time for the whole phrase.
    private func deliver(_ text: AttributedString, _ range: CMTimeRange, final: Bool) {
        guard range.start.seconds.isFinite, range.end.seconds.isFinite else { return }
        let (from, to, words, began) = lock.withLock {
            (songTime(at: range.start.seconds), songTime(at: range.end.seconds),
             Self.words(in: text) { self.songTime(at: $0) }, anchors.first?.song ?? 0)
        }
        if SongListener.debug {
            let listing = words.map { String(format: "%@@%.2f", $0.text, $0.start) }.joined(separator: " ")
            let runs = text.runs.map { run -> String in
                let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                return "[\(String(text[run.range].characters))|\(range.map { String(format: "%.2f+%.2f", $0.start.seconds, $0.duration.seconds) } ?? "-")]"
            }.joined()
            SongListener.log.notice("\(final ? "FINAL" : "volatile", privacy: .public) runs: \(runs, privacy: .public)")
            SongListener.log.notice("Heard \(from, format: .fixed(precision: 2), privacy: .public)–\(to, format: .fixed(precision: 2), privacy: .public): \(listing, privacy: .public)")
        }
        if final { output(words, from, to, began) }
    }

    /// Words with their times; a piece of text covering several words shares its time out by letters.
    static func words(in text: AttributedString, songTime: (Double) -> Double) -> [HeardWord] {
        var words: [HeardWord] = []
        for run in text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let parts = String(text[run.range].characters).split(whereSeparator: \.isWhitespace)
            let letters = parts.map(\.count).reduce(0, +)
            guard letters > 0 else { continue }
            let start = songTime(range.start.seconds)
            let length = max(0, range.duration.seconds)
            var time = start
            for part in parts {
                let share = length * Double(part.count) / Double(letters)
                words.append(HeardWord(text: String(part), start: time, end: time + share))
                time += share
            }
        }
        return words
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

// MARK: - Tap

/// The sound of one app as it goes to the speakers, through a private Core
/// Audio tap. macOS asks the user before the first one and shows the
/// recording indicator while it runs. The app keeps playing as usual.
@available(macOS 26.0, *)
final class AudioTap {
    typealias Handler = (AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    enum TapError: LocalizedError {
        case notPlaying, failed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .notPlaying: NSLocalizedString("The player is not making any sound yet.", comment: "")
            case .failed(let step, let status): "\(step) (\(status))"
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.perch.Perch.listening", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    func start(bundleId: String, handler: @escaping Handler) throws {
        let processes = Self.processes(of: bundleId)
        guard !processes.isEmpty else { throw TapError.notPlaying }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Perch"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription), "Reading the tap format")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw TapError.failed("Unknown tap format", 0)
        }

        var configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Perch listening",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if let output = AudioOutputs.defaultOutput(), let uid = Self.uid(of: output) {
            configuration[kAudioAggregateDeviceMainSubDeviceKey] = uid
            configuration[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &deviceID), "Creating the listening device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            handler(buffer, inputTime.pointee.mHostTime)
        }, "Listening")
        try check(AudioDeviceStart(deviceID, procID), "Starting to listen")
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            stop()
            throw TapError.failed(step, status)
        }
    }

    // MARK: Helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Core Audio's processes of the app, helpers included (com.example.app.helper).
    static func processes(of bundleId: String) -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &valueSize, &value) == noErr,
                  let name = value?.takeRetainedValue() as String? else { return false }
            return name == bundleId || name.hasPrefix(bundleId + ".")
        }
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// How long sound takes from the system to the ears on the current output, as the device reports it.
    static func outputLatency() -> Double {
        guard let device = AudioOutputs.defaultOutput() else { return 0 }
        func value(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID) -> UInt32 {
            var address = address(selector, scope: kAudioDevicePropertyScopeOutput)
            var result: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
            return result
        }
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate)
        guard rate > 0 else { return 0 }
        var frames = value(kAudioDevicePropertyLatency, device) + value(kAudioDevicePropertySafetyOffset, device)
        var streamsAddress = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var stream = AudioObjectID(kAudioObjectUnknown)
        var streamSize = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamSize, &stream) == noErr, stream != kAudioObjectUnknown {
            frames += value(kAudioStreamPropertyLatency, stream)
        }
        return min(0.5, Double(frames) / rate)
    }

    static func date(forHostTime hostTime: UInt64) -> Date {
        let now = AudioGetCurrentHostTime()
        let nanos = hostTime >= now
            ? Double(AudioConvertHostTimeToNanos(hostTime - now))
            : -Double(AudioConvertHostTimeToNanos(now - hostTime))
        return Date().addingTimeInterval(nanos / 1_000_000_000)
    }
}
