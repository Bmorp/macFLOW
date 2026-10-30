import SwiftUI
import AVKit

enum NowPlayingPresentation {

    // MARK: Compact

    struct Leading: View {
        let ns: Namespace.ID
        let notchHeight: CGFloat
        @ObservedObject private var media = NowPlayingModel.shared

        var body: some View {
            let size = notchHeight - 10
            ZStack {
                LeadArtwork()
                    .frame(width: size, height: size)
                    // The same hairline rim the open cover wears, so the closed island reads as the same object.
                    .overlay {
                        if media.mode == .track {
                            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                        }
                    }
                    .scaleEffect(media.mode == .track && !media.isPlaying ? 0.86 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: media.isPlaying)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { CompactProgressEdge(side: .leading, notchHeight: notchHeight) }
        }
    }

    struct Trailing: View {
        let ns: Namespace.ID
        let notchHeight: CGFloat
        @ObservedObject private var media = NowPlayingModel.shared

        var body: some View {
            // The waveform painted in the album's colours.
            let bars = Waveform(tint: .white, active: media.isLive, bars: 4, height: notchHeight * 0.42)
            Group {
                if let palette = media.palette, media.mode == .track {
                    Image(nsImage: palette).resizable().interpolation(.high)
                        .saturation(1.3).brightness(0.12)
                        .frame(width: 22, height: notchHeight * 0.42)
                        .mask(bars)
                } else {
                    Waveform(tint: ActivityKind.nowPlaying.tint, active: media.isLive, bars: 4, height: notchHeight * 0.42)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { CompactProgressEdge(side: .trailing, notchHeight: notchHeight) }
        }
    }

    // MARK: Compact progress

    /// How far into the song, as a hairline along the closed island's lower edge: it runs out from the left of the
    /// notch, under it, and on along the right, so each wing draws its own half. 1.5 pt in the album's accent over a
    /// faint track, inset to where the bottom corners' curve ends. It steps once a second while the song plays (and
    /// not at all otherwise or while the island is hidden), never per frame.
    struct CompactProgressEdge: View {
        enum Side { case leading, trailing }
        let side: Side
        let notchHeight: CGFloat
        @ObservedObject private var media = NowPlayingModel.shared
        @Environment(\.islandShowing) private var showing

        static let thickness: CGFloat = 1.5

        /// The part of the whole hairline (both wings, end to end) this wing has filled: 0…`run`.
        static func filled(fraction: Double, run: CGFloat, side: Side) -> CGFloat {
            let total = min(max(fraction, 0), 1) * Double(run) * 2
            switch side {
            case .leading: return CGFloat(min(total, Double(run)))
            case .trailing: return CGFloat(max(0, min(total - Double(run), Double(run))))
            }
        }

        var body: some View {
            if media.mode == .track, media.duration > 0 {
                TimelineView(PeriodicTimelineSchedule.seconds(showing && media.isPlaying)) { ctx in
                    GeometryReader { geo in
                        // The wing's straight run: from the corner's curve to the notch.
                        let run = max(0, geo.size.width - min(10, notchHeight / 2))
                        let mine = Self.filled(fraction: media.position(at: ctx.date) / media.duration, run: run, side: side)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.12))
                            Rectangle().fill(media.accent.opacity(0.85)).frame(width: mine)
                        }
                        .frame(width: run, height: Self.thickness)
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .bottomTrailing : .bottomLeading)
                        .padding(.bottom, 1)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Minimal

    struct Minimal: View {
        let diameter: CGFloat
        @ObservedObject private var media = NowPlayingModel.shared

        var body: some View {
            if media.mode == .app, let icon = media.otherApp?.icon {
                IconImage(image: icon, size: diameter - 10)
            } else {
                Artwork(image: media.artwork, size: diameter - 10, radius: (diameter - 10) / 2, accent: media.accent)
            }
        }
    }

    // MARK: Expanded — the album's light, seen through fluted glass.
    //  [ ART ]  Midnight City
    //  [ 112 ]  M83
    //  [     ]  ◂◂   ❚❚   ▸▸
    //  [     ]  1:37 ━━━━━━━○────────── −2:25      (the elapsed time in Ribbon numerals)

    struct Expanded: View {
        var model: IslandModel
        let ns: Namespace.ID
        @ObservedObject private var media = NowPlayingModel.shared
        @ObservedObject private var volume = SystemVolume.shared
        @Environment(\.islandShowing) private var showing

        static let artSize: CGFloat = 118
        /// The page below the notch: the cover, with the island's air above and below it.
        static let rowHeight: CGFloat = artSize + 16

        var body: some View {
            Instrument(notch: model.notch, width: model.expandedWidth, height: Self.rowHeight) {
                HStack(alignment: .center, spacing: 18) {
                    Button { media.openCurrentApp() } label: {
                        ImmersiveArtwork(size: Self.artSize)
                    }
                    .buttonStyle(PressStyle(scale: 0.96))
                    .help("Open \(media.source?.name ?? media.otherApp?.name ?? "Player")")
                    .accessibilityLabel("Open player")
                    .islandReveal(0)

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(text: title, font: .system(size: 20, weight: .semibold), color: DS.Ink.primary)
                            Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                        }
                        .islandReveal(1)
                        Spacer(minLength: 4)
                        Group {
                            if model.inlineVolume {
                                volumeIndicator
                            } else if media.mode == .app && !InputControl.isTrusted {
                                SecondaryButton(title: "Allow Control") { InputControl.requestTrust() }
                            } else {
                                controls
                            }
                        }
                        .frame(height: 38, alignment: .leading)
                        .islandReveal(2)
                        Spacer(minLength: 2)
                        timeline
                    }
                    .frame(height: Self.artSize)
                }
            }
            .background(alignment: .top) {
                PrismArtField(clearTop: model.notch.height / (model.notch.height + Self.rowHeight))
            }
        }

        private var title: String {
            media.mode == .app ? (media.otherApp?.name ?? "Audio") : media.title
        }

        private var subtitle: String {
            if media.mode == .app { return "Playing audio" }
            return media.artist.isEmpty ? media.album : media.artist
        }

        private var playing: Bool { media.mode == .app || media.isPlaying }

        private var controls: some View {
            HStack(spacing: 2) {
                Ghost(symbol: "backward.fill", label: "Previous", size: 16, hit: 34) { media.previous() }
                Ghost(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", size: 26, weight: .bold, hit: 40) {
                    media.playPause()
                }
                Ghost(symbol: "forward.fill", label: "Next", size: 16, hit: 34) { media.next() }
            }
            .padding(.leading, -8)
            .disabled(!media.canControl)
        }

        /// The time as the Ribbon numerals' two halves: "1:37" is ("1", "37"); past an hour, ("1:02", "03").
        static func ribbon(_ seconds: Double) -> (lead: String, trail: String) {
            let s = max(0, Int(seconds))
            let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
            return (h > 0 ? String(format: "%d:%02d", h, m) : "\(m)", String(format: "%02d", sec))
        }

        /// Elapsed in Ribbon numerals, a scrubbable hairline, remaining — or, for an app with no track, a live waveform.
        @ViewBuilder private var timeline: some View {
            if media.mode == .track, media.duration > 0 {
                TimelineView(PeriodicTimelineSchedule.seconds(showing && media.isPlaying)) { ctx in
                    let pos = media.position(at: ctx.date)
                    let t = Self.ribbon(pos)
                    HStack(spacing: 10) {
                        RibbonCount(lead: t.lead, trail: t.trail, fontSize: 36)
                        ProgressLine(fraction: pos / media.duration, tint: .white) { f in media.seek(to: f * media.duration) }
                            .accessibilityLabel("Position")
                            .accessibilityAdjustableAction { direction in
                                let step = direction == .increment ? 10.0 : -10.0
                                media.seek(to: min(max(0, pos + step), media.duration))
                            }
                        Text("−" + max(0, media.duration - pos).clock)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.Ink.tertiary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .frame(height: 34)
                }
            } else {
                HStack(spacing: 8) {
                    Waveform(tint: DS.Ink.secondary, active: media.isLive, bars: 5, height: 14, barWidth: 2.5)
                    Spacer()
                }
                .frame(height: 34)
            }
        }

        private var volumeIndicator: some View {
            HStack(spacing: 8) {
                Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Palette.track)
                    Capsule().fill(ActivityKind.nowPlaying.tint).frame(width: 96 * (volume.muted ? 0 : volume.volume))
                }
                .frame(width: 96, height: 6)
                .animation(.snappy, value: volume.volume)
            }
            .foregroundStyle(DS.Palette.label)
            .frame(height: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume \(Int(volume.volume * 100)) percent")
        }
    }
}

/// System AirPlay / output-device picker.
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.6), for: .normal)
        v.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        v.setRoutePickerButtonColor(NSColor.systemBlue, for: .active)
        v.setRoutePickerButtonColor(NSColor.systemBlue, for: .activeHighlighted)
        return v
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
