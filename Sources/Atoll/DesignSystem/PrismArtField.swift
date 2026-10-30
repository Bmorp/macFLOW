import SwiftUI

/// The album's light, seen through fluted glass: the colour field behind the open player, drawn as a plain SwiftUI
/// image so Prism can bend it (the drifting `ArtField` is a Core Animation layer, which a SwiftUI shader can't read).
/// The glass is static, so a song playing with the island open costs nothing per frame; what the drift gave up, the
/// strips give back as depth.
///
/// Light only: put text above it, never under it. The top stays black so the island still grows out of the bezel.
struct PrismArtField: View {
    @ObservedObject private var media = NowPlayingModel.shared
    @ObservedObject private var conditions = PrismConditions.shared
    /// How far down the island the black lasts before the colour comes in (unit height).
    var clearTop: CGFloat = 0.12
    var strength: Double = 1

    var body: some View {
        if let palette = media.palette, media.mode == .track {
            let playing = media.isPlaying
            // Reduce Transparency shades the strips over the colour itself, which reads darker than glass looking through
            // to it: give it a little more light so the two looks weigh the same.
            let lift = conditions.current.reduceTransparency ? 1.12 : 1
            GeometryReader { geo in
                Image(nsImage: palette).resizable().interpolation(.high)
                    .saturation(1.1)
                    // The edges of a 6 × 4 colour field are the softest part of it: crop them away.
                    .scaleEffect(1.25)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .prism(.nowPlaying)
                    .opacity((playing ? 0.82 : 0.42) * strength * lift)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                 .init(color: .black.opacity(0.5), location: min(0.95, clearTop + 0.2)),
                                                 .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            // Keep type legible: a soft shade over the glass, darker on the right where the controls sit.
            .overlay(Image.glow(Glow.fadeRight).foregroundStyle(Color.black.opacity(0.46)).scaleEffect(x: -1, y: 1))
            .animation(.easeInOut(duration: 0.6), value: playing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.identity)
        } else {
            // An app's audio has no cover to light the glass with: nothing, as before.
            ArtField(clearTop: clearTop)
        }
    }
}
