import Foundation

/// A word recognised in the song's audio, timed in the same seconds as the lyrics.
public struct HeardWord: Equatable, Codable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = max(start, end)
    }
}

/// Everything heard of one song so far. Speech recognition revises what it
/// said about a stretch of audio, so a new result replaces the words it covers.
public struct HeardTranscript: Equatable, Codable {
    public struct Span: Equatable, Codable {
        public var start: Double
        public var end: Double
    }

    public private(set) var words: [HeardWord] = []
    /// Stretches of the song that have been listened to, merged and in order.
    public private(set) var listened: [Span] = []

    public init(words: [HeardWord] = [], listened: [Span] = []) {
        self.words = words.sorted { $0.start < $1.start }
        listened.forEach { self.listen(from: $0.start, to: $0.end) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(words: try container.decode([HeardWord].self, forKey: .words),
                  listened: try container.decodeIfPresent([Span].self, forKey: .listened) ?? [])
    }

    public mutating func replace(from start: Double, to end: Double, with new: [HeardWord]) {
        words.removeAll { $0.start >= start && $0.start < end }
        words.append(contentsOf: new)
        words.sort { $0.start < $1.start }
    }

    public mutating func listen(from start: Double, to end: Double) {
        guard end > start else { return }
        var merged = Span(start: start, end: end)
        var rest: [Span] = []
        for span in listened {
            if span.end < merged.start || span.start > merged.end {
                rest.append(span)
            } else {
                merged = Span(start: min(span.start, merged.start), end: max(span.end, merged.end))
            }
        }
        rest.append(merged)
        listened = rest.sorted { $0.start < $1.start }
    }

    /// The share of `start…end` that has been listened to, from 0 to 1.
    public func coverage(from start: Double, to end: Double) -> Double {
        guard end > start else { return 1 }
        let heard = listened.reduce(0.0) { total, span in
            total + max(0, min(span.end, end) - max(span.start, start))
        }
        return heard / (end - start)
    }
}

/// Fits lyric words to the words heard in the song: the ones recognised get
/// their real timing, the ones in between are spread over the time left.
public enum WordAlignment {
    /// How far a heard word may be from where the lyrics expect it.
    static let window = 3.0
    /// Short words ("a", "I", "to") are everywhere; they must be close and exact.
    static let shortWindow = 1.2

    /// Lowercase letters and digits only, without accents or apostrophes: "Don't," → "dont".
    public static func normalize(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    /// 1 for the same word, falling with the number of letters that differ.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previous = row[0]
            row[0] = i
            for j in 1...y.count {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// Lyric words in order, with where they sit and where the lyrics expect them.
    struct Slot {
        let line: Int
        let word: Int
        let text: String
        let expected: Double
    }

    static func slots(_ lines: [LyricLine]) -> [Slot] {
        lines.enumerated().flatMap { lineIndex, line in
            line.words.enumerated().compactMap { wordIndex, word in
                let text = normalize(word.text)
                return text.isEmpty ? nil : Slot(line: lineIndex, word: wordIndex, text: text, expected: word.start)
            }
        }
    }

    /// How well a heard word fits a lyric word expected at `expected`; nil when it cannot be that word.
    static func score(_ slot: Slot, expected: Double, _ heard: HeardWord, heardText: String) -> Double? {
        let distance = abs(heard.start - expected)
        let short = slot.text.count <= 2 || heardText.count <= 2
        if short {
            guard slot.text == heardText, distance <= shortWindow else { return nil }
            return 0.6 * (1 - distance / (shortWindow * 2))
        }
        let similar = similarity(slot.text, heardText)
        guard similar >= 0.67, distance <= window else { return nil }
        return similar * (1 - distance / (window * 2))
    }

    /// Pairs lyric words with heard words, keeping both in order and maximising
    /// how well the pairs fit. Keys are indices into `slots(lines)`; `shifts`
    /// moves where each lyric word is expected.
    static func match(_ slots: [Slot], _ heard: [HeardWord], shifts: [Double]? = nil) -> [Int: HeardWord] {
        let texts = heard.map { normalize($0.text) }
        let n = slots.count, m = heard.count
        guard n > 0, m > 0 else { return [:] }
        // Best total for the first i lyric words and the first j heard words.
        var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var value = max(best[i - 1][j], best[i][j - 1])
                let expected = slots[i - 1].expected + (shifts?[i - 1] ?? 0)
                // Only compare words that could be close in time.
                if abs(heard[j - 1].start - expected) <= window,
                   !texts[j - 1].isEmpty,
                   let fit = score(slots[i - 1], expected: expected, heard[j - 1], heardText: texts[j - 1]) {
                    value = max(value, best[i - 1][j - 1] + fit)
                }
                best[i][j] = value
            }
        }
        var pairs: [Int: HeardWord] = [:]
        var i = n, j = m
        while i > 0, j > 0 {
            if best[i][j] == best[i - 1][j] {
                i -= 1
            } else if best[i][j] == best[i][j - 1] {
                j -= 1
            } else {
                pairs[i - 1] = heard[j - 1]
                i -= 1
                j -= 1
            }
        }
        return pairs
    }

    /// The lyrics with word timing taken from what was heard. Lines whose file
    /// already timed every word are left alone.
    ///
    /// Lyric files are often a second or two off the voice, and by about the same
    /// amount over a stretch of the song. So a first pass finds the sure matches,
    /// how far off the file is around each word follows from them, and a second
    /// pass matches again with that in mind. Lines where nothing was recognised
    /// move along with their neighbours.
    public static func align(_ lines: [LyricLine], heard: [HeardWord]) -> [LyricLine] {
        let slots = slots(lines)
        let sorted = heard.sorted { $0.start < $1.start }
        guard !slots.isEmpty, !sorted.isEmpty else { return lines }
        let first = match(slots, sorted)
        guard !first.isEmpty else { return lines }
        let pairs = match(slots, sorted, shifts: shifts(slots, first))
        let offsets = shifts(slots, pairs)
        var anchors: [Int: [Int: HeardWord]] = [:]
        for (index, word) in pairs {
            anchors[slots[index].line, default: [:]][slots[index].word] = word
        }
        // How far each line is off: that of its first word, or of the next sung line for a break.
        var lineShift = [Double](repeating: 0, count: lines.count)
        var firstSlot: [Int: Int] = [:]
        for (index, slot) in slots.enumerated() where firstSlot[slot.line] == nil { firstSlot[slot.line] = index }
        var upcoming: Double = offsets.last ?? 0
        for index in lines.indices.reversed() {
            if let slot = firstSlot[index] { upcoming = offsets[slot] }
            lineShift[index] = upcoming
        }

        var result = lines
        for index in lines.indices where !lines[index].wordSynced {
            let shifted = moved(lines[index], by: lineShift[index])
            let previous = index > 0 ? result[index - 1].time : 0
            if let lineAnchors = anchors[index] {
                let next = index + 1 < lines.count ? lines[index + 1].time + lineShift[index + 1] : nil
                result[index] = retime(shifted, anchors: lineAnchors, previous: previous, next: next)
            } else {
                result[index] = shifted
            }
            // Lines stay in order.
            if index > 0, result[index].time <= previous {
                result[index] = LyricLine(id: result[index].id, time: previous + 0.01, text: result[index].text,
                                          words: result[index].words, wordSynced: result[index].wordSynced,
                                          heard: result[index].heard)
            }
        }
        return result
    }

    /// How far off the file is around each lyric word: the median of the
    /// differences at the matched words nearby, or at the nearest one.
    static func shifts(_ slots: [Slot], _ pairs: [Int: HeardWord]) -> [Double] {
        let matched = pairs.keys.sorted()
        guard !matched.isEmpty else { return [Double](repeating: 0, count: slots.count) }
        let deltas = matched.map { pairs[$0]!.start - slots[$0].expected }
        return slots.indices.map { index in
            var near = zip(matched, deltas).filter { abs($0.0 - index) <= 12 }.map(\.1)
            if near.isEmpty {
                let nearest = zip(matched, deltas).min { abs($0.0 - index) < abs($1.0 - index) }!
                near = [nearest.1]
            }
            near.sort()
            let median = near.count.isMultiple(of: 2)
                ? (near[near.count / 2 - 1] + near[near.count / 2]) / 2
                : near[near.count / 2]
            return min(window, max(-window, median))
        }
    }

    /// A line with all its timing moved by `shift` seconds.
    static func moved(_ line: LyricLine, by shift: Double) -> LyricLine {
        guard shift != 0 else { return line }
        return LyricLine(id: line.id, time: max(0, line.time + shift), text: line.text,
                         words: line.words.map { LyricWord(text: $0.text, start: max(0, $0.start + shift), end: max(0, $0.end + shift)) },
                         wordSynced: line.wordSynced, heard: line.heard)
    }

    /// One line: anchored words take the heard times, the rest share the gaps by syllables.
    static func retime(_ line: LyricLine, anchors: [Int: HeardWord], previous: Double, next: Double?) -> LyricLine {
        let old = line.words
        var starts = old.map(\.start)
        var ends = old.map(\.end)
        let keys = anchors.keys.sorted()
        for key in keys {
            starts[key] = anchors[key]!.start
            ends[key] = anchors[key]!.end
        }
        func fill(_ range: Range<Int>, from: Double, to: Double) {
            guard !range.isEmpty else { return }
            let words = old[range].map(\.text)
            let spread = WordTiming.spread(words.joined(separator: " "), from: from, over: max(0.05, to - from))
            guard spread.count == range.count else { return }
            for (offset, word) in spread.enumerated() {
                starts[range.lowerBound + offset] = word.start
                ends[range.lowerBound + offset] = word.end
            }
        }
        // Before the first heard word: from the line's start, or just before the word.
        let first = keys[0]
        if first > 0 {
            let natural = Double(old[0..<first].map { WordTiming.syllableCount(Substring($0.text)) }.reduce(0, +)) * 0.2
            let from = max(previous, min(line.time, starts[first] - natural))
            fill(0..<first, from: from, to: starts[first])
        }
        // Between heard words.
        for (a, b) in zip(keys, keys.dropFirst()) where b > a + 1 {
            fill(a + 1..<b, from: min(ends[a], starts[b]), to: starts[b])
        }
        // After the last heard word: as long as estimated, moved along with it.
        let last = keys[keys.count - 1]
        if last + 1 < old.count {
            let span = old[old.count - 1].end - old[last + 1].start
            let from = ends[last]
            var to = from + max(0.1, span)
            if let next { to = min(to, max(from + 0.1, next - 0.05)) }
            fill(last + 1..<old.count, from: from, to: to)
        }
        // Keep words in order and each ending before the next begins.
        for index in old.indices {
            if index > 0 { starts[index] = max(starts[index], starts[index - 1]) }
            ends[index] = max(ends[index], starts[index] + 0.05)
            if index + 1 < old.count { ends[index] = min(ends[index], max(starts[index] + 0.05, starts[index + 1])) }
        }
        let words = old.indices.map { LyricWord(text: old[$0].text, start: starts[$0], end: ends[$0]) }
        // The line comes up in time for its first word, never before the line above.
        let time = max(previous + 0.01, min(line.time, starts[0]))
        return LyricLine(id: line.id, time: min(line.time, time), text: line.text, words: words,
                         wordSynced: line.wordSynced, heard: anchors.count)
    }
}
