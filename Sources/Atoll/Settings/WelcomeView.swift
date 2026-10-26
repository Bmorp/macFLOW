import SwiftUI

/// First-run welcome in Apple's "What's New" form: icon, title, a few features, Continue.
/// No permissions are requested here — each one is asked in context when its feature is first used.
struct WelcomeView: View {
    var onContinue: () -> Void
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.colorScheme) private var scheme

    private var features: [(symbol: String, tint: Color, title: String, text: String)] {
        [
            ("waveform", .pink, "Live Activities",
             "Music, calls, timers, meetings and downloads live around the notch. Rest the pointer on it to open."),
            ("magnifyingglass", .orange, "Search Everything",
             prefs.hotKey == .disabled ? "Find apps, files, answers and your clipboard from the notch."
                                       : "Press \(prefs.hotKey.label) to find apps, files, answers and your clipboard."),
            ("tray.and.arrow.down.fill", .teal, "Drop to Hold",
             "Drag files to the notch to keep them handy, or AirDrop them in one step."),
            ("square.grid.2x2.fill", .blue, "More When You Want It",
             "Desktop widgets, StandBy and a Dock companion are one switch away in Settings."),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            FlowMark(color: scheme == .dark ? .white : Brand.ink)
                .frame(height: 30)
                .padding(.top, 56)
            Text("Welcome to Mac Flow")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 14)
            Text("Your notch, alive.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 22) {
                ForEach(features, id: \.title) { f in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: f.symbol)
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(f.tint)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(.headline)
                            Text(f.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 52)
            .padding(.top, 34)

            Spacer(minLength: 24)

            Button(action: onContinue) {
                Text("Continue").frame(width: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 36)
        }
        .frame(width: 500, height: 600)
    }
}
