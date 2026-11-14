import PerchCore
import SwiftUI

/// Lyrics under the player, in the style of Apple Music: large bold lines,
/// the one being sung lit up word by word, the others dimmed and softly
/// blurred, scrolling along with the song. Tap a line to jump there.
struct LyricsPanel: View {
    @ObservedObject private var service = LyricsService.shared
    let track: Track
    let scale: CGFloat
    let seek: (Double) -> Void
    @AppStorage(Pref.lyricsSize) private var size = LyricsSize.medium
    @AppStorage(Pref.lyricsWordByWord) private var wordByWord = true

    var body: some View {
        let fontSize = size.points * scale
        Group {
            switch service.state {
            case .idle, .loading:
                message("Looking for lyrics…", progress: true)
            case .notFound:
                VStack(spacing: 8 * scale) {
                    message("No lyrics for this song")
                    Button("Add lyrics…") { UserLyricsStore.choose(for: track) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .help(Text("Choose a lyrics file for this song: LRC with timing, or plain text."))
                }
            case .failed:
                VStack(spacing: 8 * scale) {
                    message("Lyrics could not be loaded")
                    Button("Try again") { service.retry(for: track) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .loaded(.synced(let lines)):
                SyncedLyricsView(lines: lines, track: track, fontSize: fontSize, scale: scale,
                                 wordByWord: wordByWord, seek: seek, source: service.source)
            case .loaded(.plain(let lines)):
                PlainLyricsView(lines: lines, track: track, fontSize: fontSize * 0.8, scale: scale,
                                source: service.source)
            case .loaded(.instrumental):
                message("Instrumental", symbol: "music.note")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { service.load(for: track) }
        .onChange(of: track.id) { _, _ in service.load(for: track) }
    }

    private func message(_ text: LocalizedStringKey, progress: Bool = false, symbol: String? = nil) -> some View {
        HStack(spacing: 8 * scale) {
            if progress {
                ProgressView().controlSize(.small).tint(.white)
            } else if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(.system(size: 13 * scale, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }
}

/// Follows the line being sung. A timer fires exactly when the next line
/// starts, worked out from the real clock, so the highlight neither runs
/// ahead nor lags behind the song.
final class LyricsClock: ObservableObject {
    /// What to add to the reported position: a hair for rounding at a line's
    /// start, minus the player's own lead over the audio and the user's
    /// timing correction (positive delays the lyrics).
    static func shift(for track: Track) -> Double {
        0.02 - PlayerLatency.seconds(for: track.bundleId) - Pref.double(Pref.lyricsDelay)
    }

    @Published private(set) var current: Int?
    private var lines: [LyricLine] = []
    private var track: Track?
    private var timer: Timer?

    func follow(_ lines: [LyricLine], _ track: Track) {
        self.lines = lines
        self.track = track
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        stop()
        guard let track else { return }
        let position = track.position(at: Date()) + Self.shift(for: track)
        let index = LyricsTiming.currentIndex(in: lines, at: position)
        if index != current { current = index }
        guard track.isPlaying, let next = lines.first(where: { $0.time > position }) else { return }
        let rate = track.rate > 0 ? track.rate : 1
        let timer = Timer(timeInterval: max(0.01, (next.time - position) / rate), repeats: false) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }
}

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let track: Track
    let fontSize: CGFloat
    let scale: CGFloat
    let wordByWord: Bool
    let seek: (Double) -> Void
    let source: LyricsService.Source
    @StateObject private var clock = LyricsClock()
    @State private var heights: [Int: CGFloat] = [:]
    @State private var ready = false
    @AppStorage(Pref.lyricsDelay) private var delay = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the current line rests: a little above the middle, as in Apple Music.
    private let anchor: CGFloat = 0.3

    var body: some View {
        let spacing = fontSize * 0.6
        GeometryReader { geometry in
            let tops = lineTops(spacing: spacing)
            let focus = clock.current ?? 0
            let offset = (geometry.size.height * anchor - (tops.indices.contains(focus) ? tops[focus] : 0)).rounded()
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(lines) { line in
                    let distance = clock.current.map { line.id - $0 } ?? line.id + 1
                    LyricLineView(line: line, distance: distance, track: track, fontSize: fontSize,
                                  wordByWord: wordByWord, reduceMotion: reduceMotion)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: LineHeights.self, value: [line.id: proxy.size.height])
                            }
                        }
                        .offset(y: offset)
                        .animation(ready ? scroll(for: distance) : nil, value: offset)
                        .onTapGesture { seek(line.time) }
                        // Lines scrolled out of the panel still sit over the player's
                        // buttons; they must not take those clicks.
                        .allowsHitTesting(isInside(line, tops: tops, offset: offset, height: geometry.size.height))
                }
                LyricsSourceView(source: source, track: track, scale: scale)
                    .offset(y: offset)
                    .animation(ready ? scroll(for: 8) : nil, value: offset)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        .onPreferenceChange(LineHeights.self) { measured in
            heights = measured
            // Only animate once every line has its real height, so opening does not scroll.
            if !ready { DispatchQueue.main.async { ready = true } }
        }
        .onAppear { clock.follow(lines, track) }
        .onChange(of: track) { _, new in clock.follow(lines, new) }
        // Heard timing changes the times but not the text: keep scrolling smoothly then.
        .onChange(of: lines.map(\.text)) { _, _ in ready = false }
        .onChange(of: lines) { _, new in clock.follow(new, track) }
        .onChange(of: delay) { _, _ in clock.follow(lines, track) }
        .onDisappear { clock.stop() }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                   .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Lyrics"))
    }

    /// Top of each line in the list, from the measured heights.
    private func lineTops(spacing: CGFloat) -> [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for line in lines {
            tops.append(y)
            y += (heights[line.id] ?? fontSize * 1.25) + spacing
        }
        return tops
    }

    private func isInside(_ line: LyricLine, tops: [CGFloat], offset: CGFloat, height: CGFloat) -> Bool {
        guard tops.indices.contains(line.id) else { return false }
        let top = tops[line.id] + offset
        return top >= 0 && top < height - fontSize
    }

    /// The list moves like a wave rather than a block: the line now being sung
    /// leads, and each line below follows a beat later.
    private func scroll(for distance: Int) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.25) }
        let delay = Double(min(max(distance, 0), 8)) * 0.035
        return .spring(response: 0.55, dampingFraction: 0.86).delay(delay)
    }
}

private struct LineHeights: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One line of lyrics. The same view in every state, so moving between
/// "to come", "being sung" and "sung" is animated rather than swapped.
private struct LyricLineView: View {
    let line: LyricLine
    /// 0 for the line being sung, negative for past lines, positive for those to come.
    let distance: Int
    let track: Track
    let fontSize: CGFloat
    let wordByWord: Bool
    let reduceMotion: Bool

    var body: some View {
        let current = distance == 0
        let near = abs(distance) <= 6
        // Only the line being sung redraws with the display, at most 30 times a second.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(current && wordByWord && track.isPlaying))) { _ in
            // The real clock, not the timeline's date, which can lie ahead of it.
            let position = current ? track.position(at: Date()) + LyricsClock.shift(for: track) : 0
            WordFlow(spacing: fontSize * 0.28, lineSpacing: fontSize * 0.12) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    KaraokeWord(text: word.text, fill: fill(for: word, at: position), lit: current,
                                layered: abs(distance) <= 1, glow: current && wordByWord,
                                fontSize: fontSize, reduceMotion: reduceMotion)
                }
            }
        }
        .opacity(near ? (distance < 0 ? 0.65 : 1) : 0)
        .blur(radius: reduceMotion || current || !near ? 0 : min(2.2, 0.75 * CGFloat(abs(distance))))
        .scaleEffect(current || reduceMotion ? 1 : 0.97, anchor: .leading)
        .animation(.easeOut(duration: 0.45), value: distance)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: line.text.isEmpty ? "…" : line.text))
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var words: [LyricWord] {
        line.words.isEmpty ? [LyricWord(text: line.text, start: line.time, end: line.time)] : line.words
    }

    private func fill(for word: LyricWord, at position: Double) -> Double {
        if distance < 0 { return 1 } // sung; the light fades out with the line
        if distance > 0 { return 0 }
        return wordByWord ? word.progress(at: position) : 1
    }
}

/// One word: dim until sung, then filled with light from left to right
/// through a soft edge, lifting a touch and glowing while it is being sung.
private struct KaraokeWord: View {
    let text: String
    let fill: Double
    /// The light layer is showing (the line is being sung); it fades in and out.
    let lit: Bool
    /// Draw the light layer at all: only for the lines around the current one.
    let layered: Bool
    let glow: Bool
    let fontSize: CGFloat
    let reduceMotion: Bool

    var body: some View {
        // With "Reduce motion", a word simply lights up when its turn comes.
        let amount = reduceMotion ? (fill > 0 ? 1 : 0) : fill
        let singing = glow && amount > 0 && amount < 1 && !reduceMotion
        let label = Text(verbatim: text).font(.system(size: fontSize, weight: .bold))
        label
            .foregroundStyle(.white.opacity(0.4))
            .overlay {
                if layered {
                    label
                        .foregroundStyle(.white)
                        .mask { FillMask(progress: amount) }
                        .opacity(lit ? 1 : 0)
                }
            }
            .shadow(color: .white.opacity(singing ? 0.35 : 0), radius: fontSize * 0.3)
            .offset(y: singing ? -fontSize * 0.06 * sin(.pi * amount) : 0)
    }
}

private struct FillMask: View {
    let progress: Double

    var body: some View {
        if progress >= 1 {
            Color.black
        } else if progress <= 0 {
            Color.clear
        } else {
            let soft = 0.18
            let edge = progress * (1 + soft) - soft / 2
            LinearGradient(stops: [.init(color: .black, location: max(0, edge - soft / 2)),
                                   .init(color: .clear, location: min(1, edge + soft / 2))],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// Lays words out left to right and wraps them like text, so a line keeps the
/// same shape whether it is lit word by word or drawn plainly.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

private struct PlainLyricsView: View {
    let lines: [String]
    let track: Track
    let fontSize: CGFloat
    let scale: CGFloat
    let source: LyricsService.Source

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: fontSize * 0.45) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LyricsSourceView(source: source, track: track, scale: scale)
                    .padding(.top, 8 * scale)
            }
            .padding(.vertical, 12 * scale)
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                   .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Under the lyrics: where they come from, and a way to use a file of one's own instead.
private struct LyricsSourceView: View {
    let source: LyricsService.Source
    let track: Track
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6 * scale) {
            switch source {
            case .lrclib:
                Text("Lyrics from LRCLIB")
                Text(verbatim: "·")
                Button("Use your own…") { UserLyricsStore.choose(for: track) }
                    .help(Text("Choose a lyrics file for this song: LRC with timing, or plain text."))
            case .file:
                Text("Your lyrics file")
                Text(verbatim: "·")
                Button("Remove") {
                    UserLyricsStore.remove(for: track)
                    LyricsService.shared.reload(for: track)
                }
                .help(Text("Move this song's lyrics file to the Trash and look the song up in LRCLIB again."))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10 * scale, weight: .medium))
        .foregroundStyle(.white.opacity(0.3))
    }
}
