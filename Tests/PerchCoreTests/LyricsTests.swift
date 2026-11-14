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
}
