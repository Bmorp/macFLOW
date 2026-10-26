import SwiftUI
import AppKit

/// Now Playing, full screen: the cover on the album's own moving colours (the backdrop), and the lyrics floating
/// beside it, Apple Music style. With no lyrics the player takes the centre.
struct StandByNowPlayingPage: View {
    let size: CGSize
    @ObservedObject private var np = NowPlayingModel.shared
    @ObservedObject private var lyrics = LyricsModel.shared
    @ObservedObject private var prefs = Prefs.shared

    private var key: String { "\(np.title)|\(np.artist)|\(np.otherApp?.id ?? "")" }
    private var shown: Lyrics? { prefs.standByLyrics && np.mode == .track ? lyrics.lyrics : nil }

    var body: some View {
        let withLyrics = shown != nil
        HStack(spacing: 0) {
            PlayerColumn(size: size, compact: withLyrics, note: note)
                .frame(width: withLyrics ? size.width * 0.42 : size.width)
            if let shown {
                FloatingLyrics(lyrics: shown, size: CGSize(width: size.width * 0.5, height: size.height), screenHeight: size.height)
                    .id(key)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: size.width * 0.04)), removal: .opacity))
                Spacer(minLength: 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(Access.reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.8, dampingFraction: 0.86), value: withLyrics)
    }

    private var note: String? {
        guard prefs.standByLyrics, np.mode == .track else { return nil }
        switch lyrics.status {
        case .instrumental: return "Instrumental"
        default: return nil
        }
    }
}

// MARK: - Player

private struct PlayerColumn: View {
    let size: CGSize
    /// Beside lyrics: a smaller cover, everything aligned to it.
    let compact: Bool
    let note: String?
    @ObservedObject private var np = NowPlayingModel.shared

    private var key: String { "\(np.title)|\(np.artist)|\(np.otherApp?.id ?? "")" }

    var body: some View {
        let h = size.height
        let art = h * (compact ? 0.44 : 0.5)
        let paused = np.mode == .track && !np.isPlaying
        VStack(alignment: .leading, spacing: 0) {
            cover(art)
                .scaleEffect(paused ? 0.9 : 1)
                .animation(.spring(response: 0.6, dampingFraction: 0.78), value: paused)
                .padding(.bottom, h * 0.045)
            VStack(alignment: .leading, spacing: h * 0.006) {
                Text(np.mode == .app ? (np.otherApp?.name ?? "") : np.title)
                    .font(.system(size: h * 0.036, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(np.mode == .app ? "Playing audio" : (np.artist.isEmpty ? np.album : np.artist))
                    .font(.system(size: h * 0.027, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .id(key)
            .transition(.opacity)
            if np.mode == .track, np.duration > 0 {
                progress(width: art)
                    .padding(.top, h * 0.03)
            }
            HStack(spacing: 10) {
                Waveform(tint: .white.opacity(0.7), active: np.isPlaying || np.mode == .app, bars: 4, height: max(12, h * 0.014), barWidth: 2.5)
                Text(status)
                    .font(.system(size: max(12, h * 0.016), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.opacity)
            }
            .padding(.top, h * 0.022)
        }
        .frame(width: art)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 2)
        .animation(Motion.duo, value: key)
    }

    private var status: String {
        let source = (np.mode == .app ? np.otherApp?.name : np.source.map { $0 == .music ? "Apple Music" : $0.name }) ?? ""
        let parts = [np.mode == .track && !np.isPlaying ? "Paused" : source, note].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func cover(_ side: CGFloat) -> some View {
        Group {
            if np.mode == .app, let icon = np.otherApp?.icon {
                IconImage(image: icon, size: side * 0.62).frame(width: side, height: side)
            } else {
                Artwork(image: np.artwork, size: side, radius: side * 0.045, accent: np.accent)
                    .overlay(RoundedRectangle(cornerRadius: side * 0.045, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.42), radius: side * 0.12, y: side * 0.06)
            }
        }
        .id(key)
        .transition(.opacity)
    }

    private func progress(width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pos = min(np.position(at: ctx.date), np.duration)
            let h = size.height
            VStack(spacing: h * 0.009) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.92)).frame(width: max(5, width * pos / max(np.duration, 1)))
                }
                .frame(width: width, height: max(4, h * 0.0055))
                HStack {
                    Text(pos.clock)
                    Spacer()
                    Text("−" + max(0, np.duration - pos).clock)
                }
                .font(.system(size: max(12, h * 0.016), weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: width)
    }
}

// MARK: - Lyrics

/// The lyrics column. Synced lyrics follow the song line by line; unsynced ones scroll with its progress.
struct FloatingLyrics: View {
    let lyrics: Lyrics
    let size: CGSize
    let screenHeight: CGFloat
    @ObservedObject private var np = NowPlayingModel.shared

    /// Light a line a moment before it's sung, as the eye expects.
    static let lead: Double = 0.25

    var body: some View {
        let font = max(22, screenHeight * 0.047)
        if lyrics.synced {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                SyncedLyrics(lyrics: lyrics, active: lyrics.index(at: np.position(at: ctx.date) + Self.lead), size: size, font: font)
                    .equatable()
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let d = max(np.duration, 1)
                // Spread across the song, leaving a little intro and outro.
                let p = min(1, max(0, (np.position(at: ctx.date) - d * 0.06) / (d * 0.84)))
                PlainLyrics(lyrics: lyrics, progress: p, size: size, font: font * 0.82)
            }
        }
    }
}

/// Heights of lyric rows as laid out, by index.
private struct RowHeights: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Measures a line as SwiftUI will wrap it, before it has been laid out once.
private func estimatedHeight(_ text: String, font: CGFloat, width: CGFloat) -> CGFloat {
    let f = NSFont.systemFont(ofSize: font, weight: .bold)
    let r = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: f])
    return ceil(r.height)
}

private struct SyncedLyrics: View, Equatable {
    let lyrics: Lyrics
    let active: Int?
    let size: CGSize
    let font: CGFloat
    @ObservedObject private var np = NowPlayingModel.shared
    @State private var heights: [Int: CGFloat] = [:]

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.active == b.active && a.size == b.size && a.font == b.font && a.lyrics == b.lyrics
    }

    private var spacing: CGFloat { font * 0.62 }
    private var gapHeight: CGFloat { font * 0.9 }

    private func height(_ i: Int) -> CGFloat {
        if lyrics.lines[i].isGap { return i == active ? gapHeight : 0 }
        return heights[i] ?? estimatedHeight(lyrics.lines[i].text, font: font, width: size.width)
    }

    /// Top of row `i` within the column of rows (a closed gap takes no room, not even its spacing).
    private func top(_ i: Int) -> CGFloat {
        var y: CGFloat = 0
        for j in 0..<min(i, lyrics.lines.count) {
            let h = height(j)
            if h > 0 { y += h + spacing }
        }
        return y
    }

    private var motion: Animation {
        Access.reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.78, dampingFraction: 0.86)
    }

    var body: some View {
        let focus = active ?? 0
        let anchor = size.height * 0.3
        let base = top(focus)
        ZStack(alignment: .topLeading) {
            ForEach(lyrics.lines.indices, id: \.self) { i in
                let d = i - focus
                let near = d >= -5 && d <= 10
                row(i)
                    .frame(width: size.width, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RowHeights.self, value: lyrics.lines[i].isGap ? [:] : [i: g.size.height])
                    })
                    .scaleEffect(i == active ? 1 : 0.96, anchor: .leading)
                    .blur(radius: near ? blur(d) : 0)
                    .opacity(near ? opacity(d) : 0)
                    .offset(y: anchor + top(i) - base)
                    // Each line rises on its own spring, a beat after the one above it: the float.
                    .animation(motion.delay(Access.reduceMotion || d < 1 ? 0 : min(0.36, Double(d) * 0.045)), value: active)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onPreferenceChange(RowHeights.self) { h in
            MainActor.assumeIsolated { if h != heights { heights = h } }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.17),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .accessibilityElement()
        .accessibilityLabel(active.map { lyrics.lines[$0].text } ?? "")
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        let line = lyrics.lines[i]
        if line.isGap {
            if i == active {
                GapDots(start: line.time, end: lyrics.end(of: i, duration: np.duration), font: font)
                    .frame(height: gapHeight, alignment: .leading)
                    .transition(.opacity)
            } else {
                Color.clear.frame(height: 0)
            }
        } else {
            Text(line.text)
                .font(.system(size: font, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(i == active ? 0.22 : 0), radius: font * 0.3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    /// The sung line in full; upcoming ones present but quiet; sung ones fade away.
    private func opacity(_ d: Int) -> Double {
        if active == nil { return d < 6 ? 0.34 : max(0, 0.34 - Double(d - 5) * 0.08) }
        if d == 0 { return 1 }
        if d < 0 { return max(0, 0.24 + Double(d + 1) * 0.05) }
        return d <= 5 ? 0.34 : max(0, 0.34 - Double(d - 5) * 0.08)
    }

    private func blur(_ d: Int) -> CGFloat {
        guard d != 0 || active == nil else { return 0 }
        let step = font / 44
        return min(font * 0.12, CGFloat(abs(d)) * step * (d < 0 ? 1.5 : 1.1))
    }
}

/// Three dots that fill one by one across an instrumental stretch, breathing, then fold away just before the voice returns.
private struct GapDots: View {
    let start: Double
    let end: Double
    let font: CGFloat
    @ObservedObject private var np = NowPlayingModel.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !np.isPlaying || RenderMode.snapshot)) { ctx in
            let t = np.position(at: ctx.date) + FloatingLyrics.lead
            let span = max(0.5, end - start)
            let p = min(1, max(0, (t - start) / span))
            let left = end - t
            let breathe = Access.reduceMotion ? 1 : 1 + 0.07 * sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.6)
            let fold = min(1, max(0, left / 0.45))
            let d = font * 0.3
            HStack(spacing: d * 0.75) {
                ForEach(0..<3, id: \.self) { k in
                    let lit = min(1, max(0, (p * 3.3 - Double(k)) / 1))
                    Circle()
                        .fill(.white.opacity(0.32 + 0.68 * lit))
                        .frame(width: d, height: d)
                }
            }
            .scaleEffect(breathe * (0.4 + 0.6 * fold), anchor: .leading)
            .opacity(fold)
        }
    }
}

/// Lyrics without timing: one brightness, gliding up as the song goes on.
private struct PlainLyrics: View {
    let lyrics: Lyrics
    let progress: Double
    let size: CGSize
    let font: CGFloat
    @State private var heights: [Int: CGFloat] = [:]

    private var spacing: CGFloat { font * 0.55 }

    private func height(_ i: Int) -> CGFloat {
        heights[i] ?? estimatedHeight(lyrics.lines[i].text, font: font, width: size.width)
    }

    var body: some View {
        let n = lyrics.lines.count
        let tops = (0..<n).reduce(into: [CGFloat]()) { acc, i in acc.append(i == 0 ? 0 : acc[i - 1] + height(i - 1) + spacing) }
        let pos = progress * Double(max(0, n - 1))
        let i0 = Int(pos.rounded(.down)), frac = CGFloat(pos - Double(i0))
        let y = n == 0 ? 0 : tops[min(i0, n - 1)] + (i0 + 1 < n ? (tops[i0 + 1] - tops[i0]) * frac : 0)
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(lyrics.lines.indices, id: \.self) { i in
                Text(lyrics.lines[i].text)
                    .font(.system(size: font, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width, alignment: .leading)
                    .background(GeometryReader { g in Color.clear.preference(key: RowHeights.self, value: [i: g.size.height]) })
            }
        }
        .offset(y: size.height * 0.3 - y)
        .animation(.linear(duration: 1), value: progress)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onPreferenceChange(RowHeights.self) { h in
            MainActor.assumeIsolated { if h != heights { heights = h } }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.17),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}
