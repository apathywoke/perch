import Foundation
import os
import PerchCore

/// Lyrics from LRCLIB, only while the user has them turned on and opened.
/// The request carries the song's title, artist, album and length; results
/// are kept in memory only and forgotten when Perch quits.
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

    private var cache: [String: Lyrics?] = [:]
    private var cacheOrder: [String] = []
    private var currentId: String?
    private var generation = 0

    /// Shows the lyrics for `track`, fetching them if needed.
    func load(for track: Track?) {
        guard Pref.bool(Pref.lyricsEnabled), let track else {
            currentId = nil
            state = .idle
            return
        }
        guard track.id != currentId else { return }
        currentId = track.id
        if let cached = cache[track.id] {
            state = cached.map(State.loaded) ?? .notFound
            return
        }
        state = .loading
        generation += 1
        let request = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.fetch(track) }
            DispatchQueue.main.async {
                guard request == self.generation else { return } // the song changed meanwhile
                switch result {
                case .success(let lyrics):
                    self.remember(track.id, lyrics)
                    self.state = lyrics.map(State.loaded) ?? .notFound
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
        state = .loaded(lyrics)
    }

    func retry(for track: Track?) {
        currentId = nil
        load(for: track)
    }

    /// Forgets everything (the feature was turned off).
    func clear() {
        generation += 1
        cache.removeAll()
        cacheOrder.removeAll()
        currentId = nil
        state = .idle
    }

    private func remember(_ id: String, _ lyrics: Lyrics?) {
        cache[id] = .some(lyrics)
        cacheOrder.append(id)
        if cacheOrder.count > 40 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// Exact lookup first (needs the album), then a search by title and artist.
    private static func fetch(_ track: Track) throws -> Lyrics? {
        if let url = LRCLIB.getURL(title: track.title, artist: track.artist, album: track.album, duration: track.duration) {
            let response = try Network.get(url)
            if response.status == 200, let lyrics = LRCLIB.parseGet(response.data) { return lyrics }
            guard response.status == 200 || response.status == 404 else { throw NetworkError.failed("HTTP \(response.status)") }
        }
        guard let url = LRCLIB.searchURL(title: track.title, artist: track.artist) else { return nil }
        let response = try Network.get(url)
        guard response.status == 200 else { throw NetworkError.failed("HTTP \(response.status)") }
        return LRCLIB.parseSearch(response.data, duration: track.duration)
    }

    func diagnosticRows() -> [(String, String)] {
        let status = switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded(.synced(let lines)):
            lines.contains(where: \.wordSynced) ? "synced, word timing exact" : "synced, word timing estimated"
        case .loaded(.plain): "plain lyrics"
        case .loaded(.instrumental): "instrumental"
        case .notFound: "not found"
        case .failed: "failed"
        }
        return [
            ("Lyrics", Pref.bool(Pref.lyricsEnabled) ? "on" : "off"),
            ("Lyrics open", Pref.bool(Pref.lyricsOpen) ? "yes" : "no"),
            ("State", status),
            ("Songs cached in memory", "\(cache.count)"),
        ]
    }
}
