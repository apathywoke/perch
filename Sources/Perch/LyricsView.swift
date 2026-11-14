import PerchCore
import SwiftUI

/// Lyrics under the player, in the style of Apple Music: large bold lines,
/// the one being sung bright, the others dimmed and softly blurred, scrolling
/// along with the song. Tap a line to jump there.
struct LyricsPanel: View {
    @ObservedObject private var service = LyricsService.shared
    let track: Track
    let scale: CGFloat
    let seek: (Double) -> Void
    @AppStorage(Pref.lyricsSize) private var size = LyricsSize.medium

    var body: some View {
        let fontSize = size.points * scale
        Group {
            switch service.state {
            case .idle, .loading:
                message("Looking for lyrics…", progress: true)
            case .notFound:
                message("No lyrics for this song")
            case .failed:
                VStack(spacing: 8 * scale) {
                    message("Lyrics could not be loaded")
                    Button("Try again") { service.retry(for: track) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .loaded(.synced(let lines)):
                SyncedLyricsView(lines: lines, track: track, fontSize: fontSize, scale: scale, seek: seek)
            case .loaded(.plain(let lines)):
                PlainLyricsView(lines: lines, fontSize: fontSize * 0.8, scale: scale)
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

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let track: Track
    let fontSize: CGFloat
    let scale: CGFloat
    let seek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the current line rests: a little above the middle, as in Apple Music.
    private let anchor = UnitPoint(x: 0.5, y: 0.3)

    /// Redraw only when a line starts, not on a fixed tick.
    private var schedule: [Date] {
        guard track.isPlaying else { return [] }
        let now = Date()
        let rate = track.rate > 0 ? track.rate : 1
        return LyricsTiming.upcoming(in: lines, after: track.position(at: now)).prefix(400)
            .map { now.addingTimeInterval($0 / rate) }
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.explicit(schedule)) { context in
                let current = LyricsTiming.currentIndex(in: lines, at: track.position(at: context.date))
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: fontSize * 0.6) {
                            Color.clear.frame(height: geometry.size.height * anchor.y)
                            ForEach(lines) { line in
                                LyricLineView(line: line, distance: current.map { line.id - $0 } ?? line.id + 1,
                                              fontSize: fontSize, reduceMotion: reduceMotion)
                                    .id(line.id)
                                    .onTapGesture { seek(line.time) }
                            }
                            Text("Lyrics from LRCLIB")
                                .font(.system(size: 10 * scale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))
                                .padding(.top, 8 * scale)
                            Color.clear.frame(height: geometry.size.height * (1 - anchor.y))
                        }
                    }
                    .onAppear { proxy.scrollTo(current ?? 0, anchor: anchor) }
                    .onChange(of: current) { _, new in
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.88)) {
                            proxy.scrollTo(new ?? 0, anchor: anchor)
                        }
                    }
                }
            }
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                   .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Lyrics"))
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    /// 0 for the line being sung, negative for past lines, positive for those to come.
    let distance: Int
    let fontSize: CGFloat
    let reduceMotion: Bool

    var body: some View {
        let current = distance == 0
        Text(verbatim: line.text.isEmpty ? "•  •  •" : line.text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white.opacity(current ? 1 : (distance < 0 ? 0.26 : 0.4)))
            .blur(radius: reduceMotion || current ? 0 : min(2.2, 0.75 * CGFloat(abs(distance))))
            .scaleEffect(current || reduceMotion ? 1 : 0.97, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.4), value: current)
            .accessibilityAddTraits(current ? .isSelected : [])
    }
}

private struct PlainLyricsView: View {
    let lines: [String]
    let fontSize: CGFloat
    let scale: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: fontSize * 0.45) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Lyrics from LRCLIB")
                    .font(.system(size: 10 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
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
