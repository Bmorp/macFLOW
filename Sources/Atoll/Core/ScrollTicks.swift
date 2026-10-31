import SwiftUI

extension View {
    /// Put on the content of a vertical ScrollView: a detent each time another `pitch` points (a row) scrolls past
    /// the top, so two fingers feel the list go by. The engine thins a flick to its ends and plays nothing for scrolls
    /// a finger didn't make (keyboard selection, a programmatic jump).
    func scrollTicks(pitch: CGFloat, event: HapticEvent = .listRow) -> some View {
        background(alignment: .top) { ScrollTicker(pitch: pitch, event: event) }
    }
}

/// Reads where the content sits in its scroll view and ticks when the row under the top edge changes. The work per
/// scrolled frame is one subtraction and one division; nothing else re-renders.
private struct ScrollTicker: View {
    let pitch: CGFloat
    let event: HapticEvent

    var body: some View {
        GeometryReader { g in
            // Rubber-banding past the top isn't a row.
            let row = max(0, Int((-g.frame(in: .scrollView).minY / max(1, pitch)).rounded(.down)))
            Color.clear
                .onChange(of: row) { old, new in
                    guard !RenderMode.snapshot else { return }
                    HapticEngine.shared.play(event, steps: abs(new - old))
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
