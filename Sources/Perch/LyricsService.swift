import Foundation
import os
import PerchCore

/// Lyrics from the user's own files or from LRCLIB, only while the user has
/// them turned on and opened. The LRCLIB request carries the song's title,
/// artist, album and length; results are kept in memory only and forgotten
/// when Perch quits.
final class LyricsService: ObservableObject {
    static let shared = LyricsService()
    static let log = Logger(subsystem: "dev.perch.Perch", category: "lyrics")

    enum State: Equatable {
        case idle
        case loading
        case loaded(Lyrics)
        case notFound
        case failed
    }

    @Published private(set) var state: State = .idle

    enum Source: Equatable {
        case lrclib
        /// A file the user gave for the song.
        case file
    }

    @Published private(set) var source: Source = .lrclib

    private var cache: [String: Lyrics?] = [:]
    /// The synced lines as loaded, before any timing heard from the song.
    private var base: [LyricLine]?
    /// Lyrics without timing as loaded, until enough is heard to time them.
    private var untimed: [String]?
    private var duration = 0.0
    private var cacheOrder: [String] = []
    private var currentId: String?
    private var generation = 0

    /// Shows the lyrics for `track`, fetching them if needed.
    func load(for track: Track?) {
        guard Pref.bool(Pref.lyricsEnabled), let track else {
            currentId = nil
            base = nil
            untimed = nil
            state = .idle
            return
        }
        guard track.id != currentId else { return }
        if track.bundleId == MediaService.previewBundleId {
            showWithoutFetching(MediaService.previewLyrics, for: track) // the sample song in Settings
            return
        }
        currentId = track.id
        if let own = UserLyricsStore.lyrics(for: track) {
            generation += 1
            show(own, for: track, from: .file)
            return
        }
        if let cached = cache[track.id] {
            show(cached, for: track)
            return
        }
        state = .loading
        base = nil
        untimed = nil
        generation += 1
        let request = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.fetch(track) }
            DispatchQueue.main.async {
                guard request == self.generation else { return } // the song changed meanwhile
                switch result {
                case .success(let lyrics):
                    self.remember(track.id, lyrics)
                    self.show(lyrics, for: track)
                case .failure(let error):
                    Self.log.error("Lyrics request failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed
                }
            }
        }
    }

    /// Shows given lyrics without any request (Settings preview, snapshots).
    func showWithoutFetching(_ lyrics: Lyrics, for track: Track) {
        generation += 1
        currentId = track.id
        base = nil
        untimed = nil
        source = .lrclib
        state = .loaded(lyrics)
    }

    private func show(_ lyrics: Lyrics?, for track: Track, from source: Source = .lrclib) {
        base = nil
        untimed = nil
        duration = track.duration
        switch lyrics {
        case .synced(let lines): base = lines
        case .plain(let lines): untimed = lines
        default: break
        }
        self.source = source
        state = lyrics.map(State.loaded) ?? .notFound
        SongListener.shared.lyricsLoaded(for: track)
    }

    /// The synced lyrics of the song on show, without heard timing.
    func baseLines(for id: String) -> [LyricLine]? {
        id == currentId ? base : nil
    }

    /// What listening needs to know about the lyrics on show.
    struct Listenable {
        let text: String
        /// The sung part of the song; once nearly all of it was heard, the song is known.
        let span: ClosedRange<Double>?
    }

    /// The lyrics of the song on show, if hearing the song can time them better.
    func listenable(for id: String) -> Listenable? {
        guard id == currentId else { return nil }
        if let base {
            guard !base.allSatisfy({ $0.wordSynced || $0.text.isEmpty }),
                  let first = base.first(where: { !$0.text.isEmpty })?.time, let last = base.last?.time else { return nil }
            return Listenable(text: base.map(\.text).joined(separator: "\n"), span: first...max(first, last + 3))
        }
        if let untimed, !UntimedLyrics.singable(untimed).isEmpty {
            return Listenable(text: untimed.joined(separator: "\n"), span: duration > 10 ? 0...(duration - 5) : nil)
        }
        return nil
    }

    /// Times the lyrics of the song on show by the words heard in it. Lines up
    /// to `position` are kept as shown, so the line being sung never jumps.
    @discardableResult
    func retime(_ heard: [HeardWord], for id: String, keepingThrough position: Double? = nil) -> [LyricLine]? {
        guard id == currentId else { return nil }
        let start: [LyricLine]
        if let base {
            start = base
        } else if let untimed {
            // Plain text stays plain until enough of it was heard to place the lines.
            guard let timed = UntimedLyrics.time(untimed, heard: heard, duration: duration) else {
                if state != .loaded(.plain(untimed)) { state = .loaded(.plain(untimed)) }
                return nil
            }
            start = timed
        } else {
            return nil
        }
        var lines = heard.isEmpty ? start : WordAlignment.align(start, heard: heard)
        if let position, case .loaded(.synced(let shown)) = state, shown.count == lines.count,
           let current = LyricsTiming.currentIndex(in: shown, at: position) {
            lines.replaceSubrange(0...current, with: shown[0...current])
            if current + 1 < lines.count, lines[current + 1].time <= lines[current].time {
                let next = lines[current + 1]
                lines[current + 1] = LyricLine(id: next.id, time: lines[current].time + 0.01, text: next.text,
                                               words: next.words, wordSynced: next.wordSynced, heard: next.heard)
            }
        }
        if state != .loaded(.synced(lines)) { state = .loaded(.synced(lines)) }
        return lines
    }

    func retry(for track: Track?) {
        currentId = nil
        load(for: track)
    }

    /// The user added or removed lyrics for this song.
    func reload(for track: Track) {
        cache[track.id] = nil
        retry(for: track)
    }

    /// Forgets everything (the feature was turned off).
    func clear() {
        generation += 1
        cache.removeAll()
        cacheOrder.removeAll()
        base = nil
        untimed = nil
        currentId = nil
        state = .idle
    }

    private func remember(_ id: String, _ lyrics: Lyrics?) {
        cache[id] = .some(lyrics)
        cacheOrder.append(id)
        if cacheOrder.count > 40 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Exact lookup first (needs the album), then a search by title and artist.
    /// LRCLIB often keeps several records of one song, and the exact match can
    /// be one without timing while another has it, so unless the exact match is
    /// synced the search runs too and synced lyrics win.
    private static func fetch(_ track: Track) throws -> Lyrics? {
        var exact: Lyrics?
        if let url = LRCLIB.getURL(title: track.title, artist: track.artist, album: track.album, duration: track.duration) {
            let response = try Network.get(url)
            if response.status == 200 { exact = LRCLIB.parseGet(response.data) }
            guard response.status == 200 || response.status == 404 else { throw NetworkError.failed("HTTP \(response.status)") }
            if case .synced = exact { return exact }
        }
        guard let url = LRCLIB.searchURL(title: track.title, artist: track.artist) else { return exact }
        let searched: Lyrics?
        do {
            let response = try Network.get(url)
            guard response.status == 200 else { throw NetworkError.failed("HTTP \(response.status)") }
            searched = LRCLIB.parseSearch(response.data, duration: track.duration)
        } catch {
            if exact != nil { return exact }
            throw error
        }
        return LRCLIB.preferred(exact: exact, searched: searched)
    }

    func diagnosticRows() -> [(String, String)] {
        let status = switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded(.synced(let lines)):
            lines.contains(where: \.wordSynced) ? "synced, word timing exact"
                : lines.contains(where: { $0.heard > 0 }) ? "synced, word timing partly heard" : "synced, word timing estimated"
        case .loaded(.plain): "plain lyrics"
        case .loaded(.instrumental): "instrumental"
        case .notFound: "not found"
        case .failed: "failed"
        }
        return [
            ("Lyrics", Pref.bool(Pref.lyricsEnabled) ? "on" : "off"),
            ("Lyrics open", Pref.bool(Pref.lyricsOpen) ? "yes" : "no"),
            ("State", status),
            ("Source", source == .file ? "your file" : "LRCLIB"),
            ("Your lyrics files", "\(UserLyricsStore.count())"),
            ("Songs cached in memory", "\(cache.count)"),
        ]
    }
}
