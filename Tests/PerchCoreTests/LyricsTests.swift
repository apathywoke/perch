import Foundation
import Testing
@testable import PerchCore

@Suite("Lyrics")
struct LyricsTests {
    @Test func parsesTimedLines() {
        let lines = LRCParser.parse("""
        [ar:Someone]
        [ti:Song]
        [00:12.50]First line
        [00:15.00] Second line
        [01:02.345]Third
        """)
        #expect(lines.map(\.text) == ["First line", "Second line", "Third"])
        #expect(lines.map(\.time) == [12.5, 15, 62.345])
        #expect(lines.map(\.id) == [0, 1, 2])
    }

    @Test func repeatedChorusGetsEveryTimestamp() {
        let lines = LRCParser.parse("[00:30.00][00:10.00]Chorus\n[00:20.00]Verse")
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(lines.map(\.time) == [10, 20, 30])
    }

    @Test func emptyLinesAreInstrumentalBreaks() {
        let lines = LRCParser.parse("[00:01.00]Hello\n[00:05.00]\n[00:09.00]World")
        #expect(lines.map(\.text) == ["Hello", "", "World"])
    }

    @Test func positiveOffsetShowsLyricsSooner() {
        let lines = LRCParser.parse("[offset:+500]\n[00:10.00]Line")
        #expect(lines.first?.time == 9.5)
    }

    @Test func otherTimestampFormats() {
        #expect(LRCParser.timestamp("1:02") == 62)
        #expect(LRCParser.timestamp("01:02:50") == 62.5)
        #expect(LRCParser.timestamp("ar:Artist") == nil)
        #expect(LRCParser.timestamp("00:75.00") == nil)
        #expect(LRCParser.timestamp("-1:00.00") == nil)
    }

    @Test func ignoresLinesWithoutTimestamps() {
        #expect(LRCParser.parse("Just text\n\n[length:03:20]").isEmpty)
    }

    @Test func findsTheLineBeingSung() {
        let lines = LRCParser.parse("[00:10.00]A\n[00:20.00]B\n[00:30.00]C")
        #expect(LyricsTiming.currentIndex(in: lines, at: 5) == nil)
        #expect(LyricsTiming.currentIndex(in: lines, at: 10) == 0)
        #expect(LyricsTiming.currentIndex(in: lines, at: 25) == 1)
        #expect(LyricsTiming.currentIndex(in: lines, at: 300) == 2)
        #expect(LyricsTiming.currentIndex(in: [], at: 5) == nil)
    }

    @Test func listsTheUpcomingLines() {
        let lines = LRCParser.parse("[00:10.00]A\n[00:20.00]B\n[00:30.00]C")
        #expect(LyricsTiming.upcoming(in: lines, after: 15) == [5, 15])
    }

    @Test func buildsRequests() throws {
        let get = try #require(LRCLIB.getURL(title: "Song & Co", artist: "Artist", album: "Album", duration: 214.6))
        #expect(get.host == "lrclib.net")
        #expect(get.scheme == "https")
        #expect(get.absoluteString.contains("track_name=Song%20%26%20Co"))
        #expect(get.absoluteString.contains("duration=215"))
        #expect(LRCLIB.getURL(title: "Song", artist: "Artist", album: "", duration: 200) == nil)
        let search = try #require(LRCLIB.searchURL(title: "Song", artist: ""))
        #expect(search.path == "/api/search")
        #expect(!search.absoluteString.contains("artist_name"))
    }

    @Test func readsAnExactMatch() {
        let json = #"{"id":1,"instrumental":false,"plainLyrics":"A\nB","syncedLyrics":"[00:01.00]A\n[00:02.00]B"}"#
        guard case .synced(let lines) = LRCLIB.parseGet(Data(json.utf8)) else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.map(\.text) == ["A", "B"])
    }

    @Test func fallsBackToPlainAndInstrumental() {
        let plain = #"{"plainLyrics":"One\nTwo","syncedLyrics":null}"#
        #expect(LRCLIB.parseGet(Data(plain.utf8)) == .plain(["One", "Two"]))
        let instrumental = #"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#
        #expect(LRCLIB.parseGet(Data(instrumental.utf8)) == .instrumental)
        #expect(LRCLIB.parseGet(Data(#"{"plainLyrics":"  "}"#.utf8)) == nil)
    }

    @Test func searchPrefersSyncedLyricsOfTheSameLength() {
        let json = """
        [
          {"duration": 200, "plainLyrics": "Plain only"},
          {"duration": 260, "syncedLyrics": "[00:01.00]Other recording"},
          {"duration": 202, "syncedLyrics": "[00:01.00]Right one"}
        ]
        """
        guard case .synced(let lines) = LRCLIB.parseSearch(Data(json.utf8), duration: 201) else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.first?.text == "Right one")
    }

    @Test func searchRejectsOtherRecordings() {
        let json = #"[{"duration": 300, "syncedLyrics": "[00:01.00]Live version"}]"#
        #expect(LRCLIB.parseSearch(Data(json.utf8), duration: 200) == nil)
        #expect(LRCLIB.parseSearch(Data("[]".utf8), duration: 200) == nil)
    }

    @Test func syncedLyricsFromTheSearchBeatAPlainExactMatch() {
        let synced = Lyrics.synced(LRCParser.parse("[00:04.00]Line"))
        let plain = Lyrics.plain(["Line"])
        #expect(LRCLIB.preferred(exact: plain, searched: synced) == synced)
        #expect(LRCLIB.preferred(exact: .instrumental, searched: synced) == synced)
        #expect(LRCLIB.preferred(exact: synced, searched: .plain(["Other"])) == synced)
        #expect(LRCLIB.preferred(exact: plain, searched: .plain(["Other"])) == plain)
        #expect(LRCLIB.preferred(exact: nil, searched: plain) == plain)
        #expect(LRCLIB.preferred(exact: plain, searched: nil) == plain)
    }
}

@Suite("Word timing")
struct WordTimingTests {
    @Test func readsWordTimestamps() throws {
        let lines = LRCParser.parse("[00:05.50]<00:05.50>Hello <00:06.00>world<00:06.80>\n[00:09.00]Next")
        let line = try #require(lines.first)
        #expect(line.text == "Hello world")
        #expect(line.wordSynced)
        #expect(line.words == [LyricWord(text: "Hello", start: 5.5, end: 6.0),
                               LyricWord(text: "world", start: 6.0, end: 6.8)])
    }

    @Test func splitsTimedPhrasesIntoWords() throws {
        let line = try #require(LRCParser.parse("[00:01.00]<00:01.00>one two <00:02.00>three<00:03.00>").first)
        #expect(line.words.map(\.text) == ["one", "two", "three"])
        #expect(line.words.map(\.start) == [1, 1.5, 2])
        #expect(line.words.map(\.end) == [1.5, 2, 3])
    }

    @Test func wordTimestampsFollowTheOffset() throws {
        let line = try #require(LRCParser.parse("[offset:+500]\n[00:10.00]<00:10.00>Hi<00:11.00>").first)
        #expect(line.words.first == LyricWord(text: "Hi", start: 9.5, end: 10.5))
    }

    @Test func estimatesWordsFromTheLineTiming() throws {
        let lines = LRCParser.parse("[00:10.00]Hello world\n[00:14.00]Next")
        let line = try #require(lines.first)
        #expect(!line.wordSynced)
        #expect(line.words.map(\.text) == ["Hello", "world"])
        #expect(line.words.first?.start == 10)
        // "Hello" has two syllables, "world" one: twice as long.
        let hello = line.words[0].end - line.words[0].start
        let world = line.words[1].end - line.words[1].start
        #expect(abs(hello - 2 * world) < 0.0001)
        #expect(line.words[0].end == line.words[1].start)
        #expect(try #require(line.words.last).end < 14)
    }

    @Test func fastLinesFinishBeforeTheNextOne() throws {
        let lines = LRCParser.parse("[00:10.00]one two three four five six seven eight nine ten eleven twelve\n[00:12.00]Next")
        let end = try #require(lines.first?.words.last).end
        #expect(end <= 12)
        #expect(end > 11.5)
    }

    @Test func longPausesAreNotFilledWithSinging() throws {
        let lines = LRCParser.parse("[00:10.00]Short line\n[00:40.00]After a long solo")
        let end = try #require(lines.first?.words.last).end
        #expect(end < 13)
    }

    @Test func breaksGetThreeDotsAcrossThePause() throws {
        let lines = LRCParser.parse("[00:10.00]Line\n[00:20.00]\n[00:26.00]Back")
        let pause = lines[1]
        #expect(pause.words.map(\.text) == ["•", "•", "•"])
        #expect(pause.words.first?.start == 20)
        #expect(pause.words.last?.end == 26)
    }

    @Test func countsSyllablesInLatinAndCyrillic() {
        #expect(WordTiming.syllableCount("hello") == 2)
        #expect(WordTiming.syllableCount("world") == 1)
        #expect(WordTiming.syllableCount("beautiful") == 3)
        #expect(WordTiming.syllableCount("привет") == 2)
        #expect(WordTiming.syllableCount("ночь") == 1)
        #expect(WordTiming.syllableCount("hmm") == 1)
        #expect(WordTiming.syllableCount("one") == 1)
        #expect(WordTiming.syllableCount("make") == 1)
        #expect(WordTiming.syllableCount("little") == 2)
        #expect(WordTiming.syllableCount("love,") == 1)
    }

    @Test func wordProgress() {
        let word = LyricWord(text: "x", start: 10, end: 12)
        #expect(word.progress(at: 9) == 0)
        #expect(word.progress(at: 11) == 0.5)
        #expect(word.progress(at: 30) == 1)
        #expect(LyricWord(text: "y", start: 5, end: 5).progress(at: 5) == 1)
    }
}

@Suite("Player latency")
struct PlayerLatencyTests {
    @Test func onlySpotifyIsCorrected() {
        #expect(PlayerLatency.seconds(for: "com.spotify.client") == 0)
        #expect(PlayerLatency.seconds(for: "com.apple.Music") == 0)
        #expect(PlayerLatency.seconds(for: nil) == 0)
    }
}
