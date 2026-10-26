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
                    .scaleEffect(media.mode == .track && !media.isPlaying ? 0.86 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: media.isPlaying)
            }
        }
    }

    struct Trailing: View {
        let ns: Namespace.ID
        let notchHeight: CGFloat
        @ObservedObject private var media = NowPlayingModel.shared

        var body: some View {
            // The waveform painted in the album's colours.
            let bars = Waveform(tint: .white, active: media.isLive, bars: 4, height: notchHeight * 0.42)
            if let palette = media.palette, media.mode == .track {
                Image(nsImage: palette).resizable().interpolation(.high)
                    .saturation(1.3).brightness(0.12)
                    .frame(width: 22, height: notchHeight * 0.42)
                    .mask(bars)
            } else {
                Waveform(tint: ActivityKind.nowPlaying.tint, active: media.isLive, bars: 4, height: notchHeight * 0.42)
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

    // MARK: Expanded — the artwork is the instrument; its light spills into the black.
    //  [ART]  Midnight City                 ◂◂  ❚❚  ▸▸
    //         M83
    //         1:42 ━━━━━━━━○──────────── −2:21

    struct Expanded: View {
        var model: IslandModel
        let ns: Namespace.ID
        @ObservedObject private var media = NowPlayingModel.shared
        @ObservedObject private var volume = SystemVolume.shared
        @Environment(\.islandShowing) private var showing

        static let artSize: CGFloat = 58

        var body: some View {
            Instrument(notch: model.notch, width: model.expandedWidth, height: ActivityKind.nowPlaying.rowHeight) {
                HStack(alignment: .center, spacing: 14) {
                    Button { media.openCurrentApp() } label: {
                        ImmersiveArtwork(size: Self.artSize)
                    }
                    .buttonStyle(PressStyle(scale: 0.95))
                    .help("Open \(media.source?.name ?? media.otherApp?.name ?? "Player")")
                    .accessibilityLabel("Open player")
                    .islandReveal(0)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                MarqueeText(text: title, font: DS.Kit.title, color: DS.Ink.primary)
                                Text(subtitle).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .islandReveal(1)
                            Group {
                                if model.inlineVolume {
                                    volumeIndicator
                                } else if media.mode == .app && !InputControl.isTrusted {
                                    SecondaryButton(title: "Allow Control") { InputControl.requestTrust() }
                                } else {
                                    controls
                                }
                            }
                            .islandReveal(2)
                        }
                        Spacer(minLength: 4)
                        timeline
                    }
                    .frame(height: Self.artSize)
                }
            }
            .background(alignment: .top) { ArtField(clearTop: model.notch.height / (model.notch.height + ActivityKind.nowPlaying.rowHeight)) }
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
            HStack(spacing: 0) {
                Ghost(symbol: "backward.fill", label: "Previous", size: 14, hit: 32) { media.previous() }
                Ghost(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", size: 21, weight: .bold, hit: 38) {
                    media.playPause()
                }
                Ghost(symbol: "forward.fill", label: "Next", size: 14, hit: 32) { media.next() }
            }
            .disabled(!media.canControl)
        }

        /// Elapsed, a scrubbable hairline, remaining — or, for an app with no track, a live waveform.
        @ViewBuilder private var timeline: some View {
            if media.mode == .track, media.duration > 0 {
                TimelineView(PeriodicTimelineSchedule.seconds(showing && media.isPlaying)) { ctx in
                    let pos = media.position(at: ctx.date)
                    HStack(spacing: 8) {
                        Text(pos.clock).frame(minWidth: 30, alignment: .leading)
                        ProgressLine(fraction: pos / media.duration, tint: .white) { f in media.seek(to: f * media.duration) }
                        Text("−" + max(0, media.duration - pos).clock).frame(minWidth: 34, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.Ink.tertiary)
                }
            } else {
                HStack(spacing: 8) {
                    Waveform(tint: DS.Ink.secondary, active: media.isLive, bars: 5, height: 12, barWidth: 2)
                    Spacer()
                }
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
