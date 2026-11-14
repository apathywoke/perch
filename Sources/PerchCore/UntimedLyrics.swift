import Foundation

/// Lyrics without timing, timed from the words heard in the song.
///
/// With no times to start from, heard words are matched to the text by
/// spelling alone, in order. Only longer words take part, since short ones
/// ("я", "и", "the") are everywhere. Matches that disagree with their
/// neighbours about the pace are dropped. Lines with matched words start
/// when those words were sung; the rest are fitted in between at the pace
/// of the song. The result is then refined like any synced lyrics.
public enum UntimedLyrics {
    /// Matches needed before the lyrics are shown as timed.
    static let minimumAnchors = 3
    /// Shortest word, in letters, that may be matched without timing.
    static let shortestWord = 4
    static let minimumSimilarity = 0.75
    /// Lyric words either side in which a match must find agreement.
    static let neighbourhood = 12

    /// Lines that are sung: not blank, not a heading such as "[Chorus]".
    public static func singable(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !(line.hasPrefix("[") && line.hasSuffix("]")) && !WordAlignment.normalize(line).isEmpty
            }
    }

    struct Slot {
        let line: Int
        let text: String
        /// Syllables sung in the lyrics before this word.
        let syllable: Double
        let syllables: Double
    }

    /// Synced lines for `lines`, or nil while too little has been heard to place them.
    public static func time(_ lines: [String], heard: [HeardWord], duration: Double) -> [LyricLine]? {
        let texts = singable(lines)
        let sorted = heard.sorted { $0.start < $1.start }
        guard !texts.isEmpty, sorted.count >= minimumAnchors else { return nil }

        var slots: [Slot] = []
        var lineSyllables = [Double](repeating: 0, count: texts.count)
        var total = 0.0
        for (index, text) in texts.enumerated() {
            for word in WordTiming.words(of: text) {
                let normalized = WordAlignment.normalize(String(word))
                guard !normalized.isEmpty else { continue }
                let count = Double(WordTiming.syllableCount(word))
                slots.append(Slot(line: index, text: normalized, syllable: total, syllables: count))
                lineSyllables[index] += count
                total += count
            }
        }
        guard total > 0 else { return nil }

        let anchors = consistent(match(slots, sorted, total: total, duration: duration), slots)
        guard anchors.count >= minimumAnchors else { return nil }
        let pace = pace(anchors, slots)

        // Lines with matched words: from the first sung word to the last.
        var starts = [Double?](repeating: nil, count: texts.count)
        var ends = [Double?](repeating: nil, count: texts.count)
        for (line, group) in Dictionary(grouping: anchors, by: { slots[$0.slot].line }) {
            let first = group.min { $0.slot < $1.slot }!, last = group.max { $0.slot < $1.slot }!
            let lineStart = slots.first { $0.line == line }!.syllable
            let before = slots[first.slot].syllable - lineStart
            let after = lineStart + lineSyllables[line] - slots[last.slot].syllable - slots[last.slot].syllables
            starts[line] = max(0, first.word.start - before * pace)
            ends[line] = last.word.end + after * pace
        }

        // The rest: between timed lines in proportion to their syllables, and
        // before the first or after the last at the pace of the song.
        let gap = 0.3
        var times = [Double](repeating: 0, count: texts.count)
        var index = 0
        while index < texts.count {
            if let start = starts[index] {
                times[index] = start
                index += 1
                continue
            }
            var next = index
            while next < texts.count, starts[next] == nil { next += 1 }
            let run = index..<next
            if index > 0, next < texts.count {
                let from = ends[index - 1] ?? times[index - 1], to = starts[next]!
                let weights = run.map { lineSyllables[$0] }
                let sum = weights.reduce(0, +)
                var time = from + gap
                let span = max(0, to - time)
                for (line, weight) in zip(run, weights) {
                    times[line] = time
                    time += span * weight / max(sum, 1)
                }
            } else if next < texts.count {
                var time = starts[next]!
                for line in run.reversed() {
                    time -= lineSyllables[line] * pace + gap
                    times[line] = max(0, time)
                }
            } else {
                var time = (ends[index - 1] ?? times[index - 1]) + gap
                for line in run {
                    times[line] = duration > 0 ? min(time, max(0, duration - 1)) : time
                    time += lineSyllables[line] * pace + gap
                }
            }
            index = next
        }
        // Lines stay in order.
        for line in times.indices.dropFirst() where times[line] <= times[line - 1] {
            times[line] = times[line - 1] + 0.01
        }
        let entries = texts.indices.map {
            (line: LyricLine(id: $0, time: times[$0], text: texts[$0]), segments: [LRCParser.Segment]())
        }
        return WordTiming.assign(entries)
    }

    struct Anchor {
        let slot: Int
        let word: HeardWord
    }

    /// Pairs long lyric words with heard words of the same spelling, both in
    /// order. Where in the song a word falls by its place in the text breaks
    /// ties between repeats, such as a chorus sung twice.
    static func match(_ slots: [Slot], _ heard: [HeardWord], total: Double, duration: Double) -> [Anchor] {
        let texts = heard.map { WordAlignment.normalize($0.text) }
        let n = slots.count, m = heard.count
        guard n > 0, m > 0 else { return [] }
        func fit(_ slot: Slot, _ j: Int) -> Double? {
            let a = slot.text, b = texts[j]
            guard a.count >= shortestWord, b.count >= shortestWord,
                  abs(a.count - b.count) * 3 <= max(a.count, b.count) else { return nil }
            let similar = WordAlignment.similarity(a, b)
            guard similar >= minimumSimilarity else { return nil }
            guard duration > 0 else { return similar }
            let expected = duration * (0.05 + 0.9 * slot.syllable / total)
            return similar * (1 - 0.5 * min(1, abs(heard[j].start - expected) / (0.35 * duration)))
        }
        var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var took = [[Bool]](repeating: [Bool](repeating: false, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var value = max(best[i - 1][j], best[i][j - 1])
                if let score = fit(slots[i - 1], j - 1), best[i - 1][j - 1] + score > value {
                    value = best[i - 1][j - 1] + score
                    took[i][j] = true
                }
                best[i][j] = value
            }
        }
        var anchors: [Anchor] = []
        var i = n, j = m
        while i > 0, j > 0 {
            if took[i][j] {
                anchors.append(Anchor(slot: i - 1, word: heard[j - 1]))
                i -= 1
                j -= 1
            } else if best[i][j] == best[i - 1][j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return anchors.reversed()
    }

    /// Whether two matches can both be right: the words between them sung at a
    /// human pace, allowing for an instrumental break.
    static func agree(_ a: Anchor, _ b: Anchor, _ slots: [Slot]) -> Bool {
        let (first, second) = a.slot < b.slot ? (a, b) : (b, a)
        let syllables = slots[second.slot].syllable - slots[first.slot].syllable
        let seconds = second.word.start - first.word.start
        return seconds > 0 && seconds >= syllables * 0.06 && seconds <= syllables * 0.7 + 25
    }

    /// Drops matches that no nearby match agrees with: a word heard by chance
    /// somewhere else in the song.
    static func consistent(_ anchors: [Anchor], _ slots: [Slot]) -> [Anchor] {
        var kept = anchors
        for _ in 0..<2 {
            kept = kept.enumerated().filter { index, anchor in
                kept.indices.contains { other in
                    other != index && abs(kept[other].slot - anchor.slot) <= neighbourhood
                        && agree(anchor, kept[other], slots)
                }
            }.map(\.element)
        }
        return kept
    }

    /// Seconds per syllable, from matches close together in the lyrics.
    static func pace(_ anchors: [Anchor], _ slots: [Slot]) -> Double {
        var paces: [Double] = []
        for (a, b) in zip(anchors, anchors.dropFirst()) where slots[a.slot].line == slots[b.slot].line {
            let syllables = slots[b.slot].syllable - slots[a.slot].syllable
            guard syllables >= 2 else { continue }
            paces.append((b.word.start - a.word.start) / syllables)
        }
        guard !paces.isEmpty else { return 0.25 }
        paces.sort()
        return min(0.6, max(0.12, paces[paces.count / 2]))
    }
}

/// Lyrics files the user gives Perch for songs LRCLIB lacks, named
/// "Artist - Title.lrc". LRC with or without timing, or plain text.
public enum UserLyrics {
    public static let maximumSize = 512 * 1024

    /// The file name Perch gives a song's lyrics.
    public static func fileName(title: String, artist: String) -> String {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "/", with: "∕")
                .replacingOccurrences(of: ":", with: "꞉")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
        let name = artist.isEmpty ? clean(title) : "\(clean(artist)) - \(clean(title))"
        return String(name.prefix(200)) + ".lrc"
    }

    /// Whether a file named `stem` (without extension) holds this song's lyrics.
    /// The artist part may list more artists than the player gives, or fewer.
    public static func matches(stem: String, title: String, artist: String) -> Bool {
        let wantedTitle = WordAlignment.normalize(title)
        guard !wantedTitle.isEmpty, let dash = stem.range(of: " - ") else { return false }
        let fileArtist = WordAlignment.normalize(String(stem[..<dash.lowerBound]))
        let fileTitle = WordAlignment.normalize(String(stem[dash.upperBound...]))
        guard fileTitle == wantedTitle else { return false }
        let wantedArtist = WordAlignment.normalize(artist)
        guard !wantedArtist.isEmpty, !fileArtist.isEmpty else { return wantedArtist == fileArtist }
        return fileArtist.contains(wantedArtist) || wantedArtist.contains(fileArtist)
    }

    /// Text from a file: UTF-8 or UTF-16, else Windows Cyrillic, as old Russian files often are.
    public static func decode(_ data: Data) -> String? {
        guard data.count <= maximumSize else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return String(data: data, encoding: .windowsCP1251)
    }

    /// Synced lyrics when the file has timestamps, plain lines otherwise.
    public static func parse(_ text: String) -> Lyrics? {
        let synced = LRCParser.parse(text)
        if synced.contains(where: { !$0.text.isEmpty }) { return .synced(synced) }
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isTag($0) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.contains { !$0.isEmpty } ? .plain(lines) : nil
    }

    /// An LRC header such as "[ar: Artist]" or "[length: 2:30]".
    static func isTag(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"), let colon = line.firstIndex(of: ":") else { return false }
        let name = line[line.index(after: line.startIndex)..<colon]
        return !name.isEmpty && name.allSatisfy { $0.isASCII && $0.isLetter }
    }
}
