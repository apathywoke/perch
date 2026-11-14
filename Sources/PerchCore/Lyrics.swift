import Foundation

public struct LyricWord: Equatable {
    public let text: String
    /// When the word starts and ends being sung, in seconds from the beginning of the song.
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// How much of the word has been sung at `position`, from 0 to 1.
    public func progress(at position: Double) -> Double {
        guard end > start else { return position >= start ? 1 : 0 }
        return min(1, max(0, (position - start) / (end - start)))
    }
}

public struct LyricLine: Equatable, Identifiable {
    public let id: Int
    /// Start of the line, in seconds from the beginning of the song.
    public let time: Double
    /// Empty for an instrumental break.
    public let text: String
    /// Words with their timing; for a break, three dots spread over the pause.
    public var words: [LyricWord]
    /// The file gave the timing of each word; otherwise it is estimated.
    public var wordSynced: Bool
    /// How many of the words were timed from the song's audio.
    public var heard: Int

    public init(id: Int, time: Double, text: String, words: [LyricWord] = [], wordSynced: Bool = false, heard: Int = 0) {
        self.id = id
        self.time = time
        self.text = text
        self.words = words
        self.wordSynced = wordSynced
        self.heard = heard
    }
}

public enum Lyrics: Equatable {
    /// Lines with timestamps: the current one can be highlighted.
    case synced([LyricLine])
    /// Text without timing.
    case plain([String])
    case instrumental
}

// MARK: - LRC

/// Reads the LRC format: `[mm:ss.xx]text`, several stamps per line allowed,
/// `[offset:±ms]` honoured, other tags (`[ar:…]`, `[ti:…]`) ignored.
public enum LRCParser {
    public static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var stamped: [(time: Double, order: Int, text: String, words: [Segment])] = []
        var order = 0
        for rawLine in text.components(separatedBy: .newlines) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex)..<close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000
                }
                line = line[line.index(after: close)...]
            }
            // Enhanced LRC: <mm:ss.xx> before each word or phrase.
            let segments = wordSegments(line)
            let words = segments.map { $0.map(\.text).joined(separator: " ") }
                ?? line.trimmingCharacters(in: .whitespaces)
            for time in times {
                stamped.append((time, order, words, segments ?? []))
                order += 1
            }
        }
        // A positive offset makes the lyrics appear sooner.
        let lines = stamped
            .sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            .enumerated()
            .map { index, entry in
                (line: LyricLine(id: index, time: max(0, entry.time - offset), text: entry.text),
                 segments: entry.words.map { Segment(start: max(0, $0.start - offset), end: $0.end.map { max(0, $0 - offset) }, text: $0.text) })
            }
        return WordTiming.assign(lines)
    }

    /// A timed piece of an enhanced LRC line: one word or a phrase.
    struct Segment {
        let start: Double
        var end: Double?
        let text: String
    }

    /// Splits `<00:01.00>Hello <00:01.50>world<00:02.00>` into timed segments;
    /// nil when the line has no word timing.
    static func wordSegments(_ line: Substring) -> [Segment]? {
        var segments: [Segment] = []
        var pending: Double?
        var buffer = ""
        var rest = line[...]
        while !rest.isEmpty {
            if rest.first == "<", let close = rest.firstIndex(of: ">"),
               let time = timestamp(rest[rest.index(after: rest.startIndex)..<close]) {
                let text = buffer.trimmingCharacters(in: .whitespaces)
                if let pending, !text.isEmpty {
                    segments.append(Segment(start: pending, end: time, text: text))
                } else if !text.isEmpty, segments.isEmpty {
                    return nil // words before the first tag: not something we can time
                }
                if let last = segments.indices.last, segments[last].end == nil { segments[last].end = time }
                pending = time
                buffer = ""
                rest = rest[rest.index(after: close)...]
            } else {
                buffer.append(rest.removeFirst())
            }
        }
        let text = buffer.trimmingCharacters(in: .whitespaces)
        if let pending, !text.isEmpty { segments.append(Segment(start: pending, end: nil, text: text)) }
        return segments.isEmpty ? nil : segments
    }

    /// "01:02.34", "1:02", "01:02:340" → seconds.
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0,
              parts[0].allSatisfy(\.isNumber) else { return nil }
        let rest = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(rest), seconds >= 0, seconds < 60,
              rest.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + seconds
    }
}

// MARK: - Word timing

public enum WordTiming {
    /// Seconds per syllable when nothing better is known: a moderate singing pace.
    static let secondsPerSyllable = 0.3

    /// Gives every line its words with timing. Lines from enhanced LRC keep
    /// their exact times; for the others the time until the next line is
    /// shared out by syllables. A break gets three dots spread over the pause.
    static func assign(_ entries: [(line: LyricLine, segments: [LRCParser.Segment])]) -> [LyricLine] {
        entries.indices.map { index in
            var line = entries[index].line
            let next = index + 1 < entries.count ? entries[index + 1].line.time : nil
            let available = max(0.3, (next ?? line.time + 6) - line.time)
            let segments = entries[index].segments
            if !segments.isEmpty {
                line.words = segments.enumerated().flatMap { position, segment in
                    let fallbackEnd = position + 1 < segments.count ? segments[position + 1].start : line.time + available
                    let end = max(segment.start, segment.end ?? fallbackEnd)
                    return spread(segment.text, from: segment.start, over: end - segment.start)
                }
                line.wordSynced = true
            } else if line.text.isEmpty {
                // Dots fill up while the music plays on; the last one ends with the pause.
                line.words = (0..<3).map { dot in
                    LyricWord(text: "•", start: line.time + available * Double(dot) / 3,
                              end: line.time + available * Double(dot + 1) / 3)
                }
            } else {
                line.words = spread(line.text, from: line.time, over: singingTime(for: line.text, available: available))
            }
            return line
        }
    }

    /// How long a line is sung: its natural length at a moderate pace, stretched
    /// towards the time available but never into a long instrumental gap.
    static func singingTime(for text: String, available: Double) -> Double {
        let syllables = Double(words(of: text).map(syllableCount).reduce(0, +))
        let natural = syllables * secondsPerSyllable + 0.2
        return min(available * 0.92, max(natural, min(available * 0.6, natural * 2.2)))
    }

    /// Shares `duration` among the words of `text` by syllables.
    static func spread(_ text: String, from start: Double, over duration: Double) -> [LyricWord] {
        let parts = words(of: text)
        let weights = parts.map { Double(syllableCount($0)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        var time = start
        return zip(parts, weights).map { word, weight in
            let length = duration * weight / total
            defer { time += length }
            return LyricWord(text: String(word), start: time, end: time + length)
        }
    }

    static func words(of text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// Groups of vowels, Latin and Cyrillic; at least one per word.
    static func syllableCount(_ word: Substring) -> Int {
        let vowels = Set("aeiouyáéíóúàèìòùäöüâêîôûæøåœаеёиоуыэюяіїєў")
        var count = 0
        var previousWasVowel = false
        let letters = Array(word.lowercased().filter(\.isLetter))
        for character in letters {
            let isVowel = vowels.contains(character)
            if isVowel, !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        // English silent "e": one, make, love; but not little, table.
        if count > 1, letters.count > 2, letters.last == "e",
           !vowels.contains(letters[letters.count - 2]), letters[letters.count - 2] != "l" {
            count -= 1
        }
        return max(1, count)
    }
}

// MARK: - Timing

public enum LyricsTiming {
    /// The line being sung at `position`; nil before the first one.
    public static func currentIndex(in lines: [LyricLine], at position: Double) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].time <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// Start times of the lines still to come, as seconds from `position`.
    public static func upcoming(in lines: [LyricLine], after position: Double) -> [Double] {
        lines.lazy.filter { $0.time > position }.map { $0.time - position }
    }
}

// MARK: - LRCLIB

/// Requests to lrclib.net, a free, open lyrics database.
public enum LRCLIB {
    public static let host = "lrclib.net"

    /// Exact lookup; needs the album and the length.
    public static func getURL(title: String, artist: String, album: String, duration: Double) -> URL? {
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty, duration > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/get"
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        return components.url
    }

    public static func searchURL(title: String, artist: String) -> URL? {
        guard !title.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/search"
        components.queryItems = [URLQueryItem(name: "track_name", value: title)]
            + (artist.isEmpty ? [] : [URLQueryItem(name: "artist_name", value: artist)])
        return components.url
    }

    /// One record from /api/get or /api/search.
    public static func lyrics(from record: [String: Any]) -> Lyrics? {
        if let synced = record["syncedLyrics"] as? String {
            let lines = LRCParser.parse(synced)
            if lines.contains(where: { !$0.text.isEmpty }) { return .synced(lines) }
        }
        if let plain = record["plainLyrics"] as? String,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if record["instrumental"] as? Bool == true { return .instrumental }
        return nil
    }

    public static func parseGet(_ data: Data) -> Lyrics? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lyrics(from: record)
    }

    /// The exact match unless it lacks timing and the search found lyrics with it.
    public static func preferred(exact: Lyrics?, searched: Lyrics?) -> Lyrics? {
        if case .synced = exact { return exact }
        if case .synced = searched { return searched }
        return exact ?? searched
    }

    /// Picks the best search result: synced over plain, then the closest length.
    public static func parseSearch(_ data: Data, duration: Double) -> Lyrics? {
        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        func distance(_ record: [String: Any]) -> Double {
            guard duration > 0, let length = number(record["duration"]) else { return 0 }
            return abs(length - duration)
        }
        let candidates = records
            .filter { duration <= 0 || distance($0) <= 5 } // a different recording is worse than nothing
            .compactMap { record in lyrics(from: record).map { (lyrics: $0, distance: distance(record)) } }
        func rank(_ lyrics: Lyrics) -> Int {
            switch lyrics {
            case .synced: 0
            case .plain: 1
            case .instrumental: 2
            }
        }
        return candidates.min {
            (rank($0.lyrics), $0.distance) < (rank($1.lyrics), $1.distance)
        }?.lyrics
    }
}

// MARK: - Player latency

/// How far a player's reported position runs ahead of what is actually heard.
public enum PlayerLatency {
    /// None: while lyrics are open Perch keeps a Spotify song's position in step
    /// with Spotify's own (SpotifyClock), which matches what is heard. The
    /// position Spotify gives the system runs 0.2 s ahead to 0.5 s behind it.
    public static let spotify = 0.0

    public static func seconds(for bundleId: String?) -> Double {
        bundleId == FallbackPlayer.spotify.rawValue ? spotify : 0
    }
}
