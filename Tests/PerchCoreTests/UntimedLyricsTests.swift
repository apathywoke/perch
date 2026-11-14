import Foundation
import Testing
@testable import PerchCore

@Suite("Untimed lyrics")
struct UntimedLyricsTests {
    private let text = [
        "[Verse 1]",
        "Walking down the empty street tonight",
        "Lights are burning everywhere around",
        "",
        "Nobody remembers anything at all",
        "Waiting for the morning light to come",
    ]

    /// When the words are really sung.
    private let truth = LRCParser.parse("""
    [00:10.00]Walking down the empty street tonight
    [00:14.00]Lights are burning everywhere around
    [00:18.00]Nobody remembers anything at all
    [00:22.00]Waiting for the morning light to come
    """)

    /// The longer words of the given lines, heard when they are sung.
    private func heard(lines: [Int], shift: Double = 0) -> [HeardWord] {
        lines.flatMap { truth[$0].words }
            .filter { WordAlignment.normalize($0.text).count >= 4 }
            .map { HeardWord(text: $0.text, start: $0.start + shift, end: $0.end + shift) }
    }

    @Test func singableLinesSkipHeadingsAndBlanks() {
        #expect(UntimedLyrics.singable(text) == truth.map(\.text))
    }

    @Test func linesTakeTheTimesTheyWereHeardAt() throws {
        let lines = try #require(UntimedLyrics.time(text, heard: heard(lines: [0, 2, 3]), duration: 60))
        #expect(lines.map(\.text) == truth.map(\.text))
        for index in [0, 2, 3] {
            #expect(abs(lines[index].time - truth[index].time) < 0.4)
        }
        // The line nobody heard sits between its neighbours.
        #expect(lines[1].time > lines[0].time + 1 && lines[1].time < lines[2].time - 1)
    }

    @Test func refiningKeepsTheHeardTiming() throws {
        let words = heard(lines: [0, 2, 3])
        let timed = try #require(UntimedLyrics.time(text, heard: words, duration: 60))
        let refined = WordAlignment.align(timed, heard: words)
        #expect(refined[0].heard >= 3)
        #expect(abs(refined[2].words[0].start - truth[2].words[0].start) < 0.01)
    }

    @Test func linesBeforeAnythingHeardComeEarlier() throws {
        let lines = try #require(UntimedLyrics.time(text, heard: heard(lines: [2, 3]), duration: 60))
        #expect(lines[0].time < lines[1].time && lines[1].time < lines[2].time)
        #expect(abs(lines[2].time - 18) < 0.4)
    }

    @Test func staysPlainUntilEnoughIsHeard() {
        #expect(UntimedLyrics.time(text, heard: [], duration: 60) == nil)
        #expect(UntimedLyrics.time(text, heard: Array(heard(lines: [0]).prefix(2)), duration: 60) == nil)
    }

    @Test func aWordHeardFarAwayIsIgnored() throws {
        var words = heard(lines: [0, 2, 3])
        words.append(HeardWord(text: "everywhere", start: 140, end: 140.5))
        let lines = try #require(UntimedLyrics.time(text, heard: words, duration: 180))
        #expect(lines[1].time < 18)
    }

    @Test func aRepeatedChorusIsPlacedWhereItWasHeard() throws {
        let song = ["Hold me closer tonight darling", "Something different happens here",
                    "Another verse continues onwards", "Hold me closer tonight darling"]
        let words = ["Hold", "closer", "tonight", "darling"].enumerated().map { index, word in
            HeardWord(text: word, start: 40 + Double(index) * 0.5, end: 40.4 + Double(index) * 0.5)
        }
        let lines = try #require(UntimedLyrics.time(song, heard: words, duration: 60))
        #expect(abs(lines[3].time - 40) < 0.5)
        // The first chorus was not heard: it comes before, at the pace of the song.
        #expect(lines[0].time < lines[3].time - 5)
    }

    // MARK: Files

    @Test func namesFilesByArtistAndTitle() {
        #expect(UserLyrics.fileName(title: "WATER", artist: "elox1m") == "elox1m - WATER.lrc")
        #expect(UserLyrics.fileName(title: "AC/DC: live", artist: "") == "AC∕DC꞉ live.lrc")
        #expect(!UserLyrics.fileName(title: "..hidden", artist: "").hasPrefix("."))
    }

    @Test func findsFilesNamedByHand() {
        #expect(UserLyrics.matches(stem: "elox1m - WATER", title: "WATER", artist: "elox1m"))
        #expect(UserLyrics.matches(stem: "elox1m, ghasaii - Water", title: "WATER", artist: "elox1m"))
        #expect(UserLyrics.matches(stem: "Elox1m - WATER", title: "WATER", artist: "elox1m, ghasaii"))
        #expect(!UserLyrics.matches(stem: "elox1m - SOLO", title: "WATER", artist: "elox1m"))
        #expect(!UserLyrics.matches(stem: "someone - WATER", title: "WATER", artist: "elox1m"))
        #expect(!UserLyrics.matches(stem: "WATER", title: "WATER", artist: "elox1m"))
    }

    @Test func readsTimedAndPlainFiles() {
        guard case .synced(let lines) = UserLyrics.parse("[ar:elox1m]\n[00:05.00]First\n[00:08.00]Second") else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.map(\.text) == ["First", "Second"])
        #expect(UserLyrics.parse("[ar: elox1m]\n[ti: WATER]\n\nFirst line\n\n[Chorus]\nSecond\n")
                == .plain(["First line", "", "[Chorus]", "Second"]))
        #expect(UserLyrics.parse("[ar: elox1m]\n\n") == nil)
    }

    @Test func readsWindowsCyrillic() throws {
        let data = try #require("Привет, вода".data(using: .windowsCP1251))
        #expect(UserLyrics.decode(data) == "Привет, вода")
        #expect(UserLyrics.decode(Data("\u{FEFF}Вода".utf8)) == "Вода")
        #expect(UserLyrics.decode(Data(count: UserLyrics.maximumSize + 1)) == nil)
    }
}
