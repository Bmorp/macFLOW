import SwiftUI
import AppKit

/// The island's Controls, as Control Center modules: each one says what it is, then lets you change it.
///   Sound    — volume, and the output in use (its full name, one click to switch)
///   Display  — brightness, Night Shift, True Tone
///   Input    — the microphone (and mute), the keyboard backlight
struct ControlsView: View {
    var model: IslandModel
    @ObservedObject private var volume = SystemVolume.shared
    @ObservedObject private var audio = AudioDevices.shared
    @ObservedObject private var display = DisplayControl.shared
    @Environment(\.islandShowing) private var showing

    static let height: CGFloat = 200
    static let side: CGFloat = 178

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ControlModule(title: "Sound", value: volume.muted ? "Muted" : "\(Int((volume.volume * 100).rounded()))%") {
                        ControlSlider(value: volume.muted ? 0 : volume.volume, symbol: volume.symbol, label: "Volume",
                                      tapSymbol: { volume.setMuted(!volume.muted) }) { v in
                            IslandManager.shared.noteOwnVolumeChange()
                            volume.set(v)
                        }
                    }
                    DeviceModule(title: "Output", name: audio.currentOutput?.name ?? "No Output",
                                 symbol: audio.currentOutput?.symbol ?? "speaker.wave.2.fill",
                                 devices: audio.outputs, selected: audio.output) { audio.useOutput($0) }
                        .frame(width: Self.side)
                }
                .frame(height: 62)
                HStack(spacing: 10) {
                    if display.canSetBrightness {
                        ControlModule(title: "Display", value: "\(Int((display.brightness * 100).rounded()))%") {
                            ControlSlider(value: display.brightness, symbol: display.brightness < 0.33 ? "sun.min.fill" : "sun.max.fill",
                                          label: "Brightness") { display.setBrightness($0) }
                        }
                    }
                    HStack(spacing: 10) {
                        if display.hasNightShift {
                            ToggleModule(symbol: "moon.fill", label: "Night Shift", on: display.nightShift, tint: DS.Palette.orange) {
                                display.setNightShift(!display.nightShift)
                            }
                        }
                        if display.hasTrueTone {
                            ToggleModule(symbol: "circle.lefthalf.filled", label: "True Tone", on: display.trueTone, tint: DS.Palette.blue) {
                                display.setTrueTone(!display.trueTone)
                            }
                        }
                    }
                    .frame(width: display.canSetBrightness ? Self.side : nil)
                }
                .frame(height: 62)
                HStack(spacing: 10) {
                    MicrophoneModule(audio: audio)
                    if display.hasKeyboard {
                        ControlModule(title: nil, value: nil, compact: true) {
                            ControlSlider(value: display.keyboard, symbol: "light.max", label: "Keyboard Brightness", showsValue: false) {
                                display.setKeyboard($0)
                            }
                        }
                        .frame(width: Self.side)
                    }
                }
                .frame(height: 44)
            }
            .padding(.horizontal, IslandModel.expandedFlare + DS.Island.rowLeading)
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
        .frame(width: model.expandedSize(.controls).width, alignment: .top)
        .onChange(of: showing) { _, on in if on { refreshDisplaySoon() } }
    }

    /// Devices and volume are kept live by CoreAudio listeners. Display state (Night Shift can change on a schedule)
    /// is re-read once the opening spring has settled — never inside its frames.
    private func refreshDisplaySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { DisplayControl.shared.refresh() }
    }
}

/// A Control Center module: a soft rounded panel, its name and reading on top, its control below.
struct ControlModule<Content: View>: View {
    let title: String?
    let value: String?
    var compact = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                HStack {
                    Text(title).font(DS.Kit.caption.weight(.semibold)).foregroundStyle(DS.Ink.secondary)
                    Spacer()
                    if let value {
                        Text(value).font(DS.Kit.caption).foregroundStyle(DS.Ink.tertiary).contentTransition(.numericText())
                    }
                }
            }
            content
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 10 : 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(ModuleSurface())
    }
}

/// The panel every module sits on.
struct ModuleSurface: View {
    var lit = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape.fill(Color.white.opacity(lit ? 0.12 : 0.07))
            .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

/// A Control Center slider bar: drag or scroll anywhere on it; the fill carries the glyph.
struct ControlSlider: View {
    let value: Double
    let symbol: String
    let label: String
    var showsValue = false
    var tapSymbol: (() -> Void)? = nil
    let onChange: (Double) -> Void

    @State private var drag: Double?
    @State private var hover = false
    @State private var startValue = 0.0

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let v = min(1, max(0, drag ?? value))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(hover ? 0.16 : 0.11))
                Capsule().fill(Color.white)
                    .frame(width: max(geo.size.height, w * v))
                    .animation(drag == nil ? .smooth(duration: 0.25) : nil, value: v)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: geo.size.height, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { tapSymbol?() }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if drag == nil { startValue = value }
                    // Relative drag (like Control Center): grab anywhere, move by the distance travelled.
                    let next = min(1, max(0, startValue + Double(g.translation.width / w)))
                    if (next == 0 || next == 1) && next != drag { Haptics.snap() }
                    drag = next
                    onChange(next)
                }
                .onEnded { _ in drag = nil })
            .background(ScrollCatcher { dy in onChange(min(1, max(0, value + dy * 0.006))) })
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in onChange(min(1, max(0, value + (dir == .increment ? 0.0625 : -0.0625)))) }
    }
}

/// A toggle module: a round glyph that fills with its colour when on, and its name under it.
struct ToggleModule: View {
    let symbol: String
    let label: String
    let on: Bool
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.white : DS.Ink.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(on ? tint : Color.white.opacity(0.12)))
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(on ? DS.Ink.primary : DS.Ink.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ModuleSurface(lit: hover))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A device module: what it is, the device in use by its full name (two lines if it needs them), and a menu of
/// every other one.
struct DeviceModule: View {
    let title: String
    let name: String
    let symbol: String
    let devices: [AudioDevices.Device]
    let selected: UInt32
    let choose: (AudioDevices.Device) -> Void
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(devices) { d in
                Button { choose(d) } label: {
                    Label(d.name, systemImage: d.id == selected ? "checkmark" : d.symbol)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Ink.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.Kit.caption.weight(.semibold)).foregroundStyle(DS.Ink.secondary)
                    Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ModuleSurface(lit: hover))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("\(title): \(name)")
    }
}

/// The microphone: mute on the left, the device in use (menu) beside it.
struct MicrophoneModule: View {
    @ObservedObject var audio: AudioDevices
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button { audio.setInputMuted(!audio.inputMuted) } label: {
                Image(systemName: audio.inputMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(audio.inputMuted ? Color.white : DS.Ink.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(audio.inputMuted ? DS.Palette.red : Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help(audio.inputMuted ? "Unmute Microphone" : "Mute Microphone")
            .accessibilityLabel(audio.inputMuted ? "Unmute Microphone" : "Mute Microphone")
            Menu {
                ForEach(audio.inputs) { d in
                    Button { audio.useInput(d) } label: {
                        Label(d.name, systemImage: d.id == audio.input ? "checkmark" : d.symbol)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(audio.inputMuted ? "Microphone Muted" : (audio.currentInput?.name ?? "Microphone"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(audio.inputMuted ? DS.Palette.red : DS.Ink.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Microphone: \(audio.currentInput?.name ?? "none")")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(ModuleSurface(lit: hover))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Two-finger scroll over a control adjusts it.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (Double) -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Void)?
        override func scrollWheel(with e: NSEvent) {
            let natural = e.isDirectionInvertedFromDevice
            let dy = Double(natural ? e.scrollingDeltaY : -e.scrollingDeltaY)
            let dx = Double(natural ? -e.scrollingDeltaX : e.scrollingDeltaX)
            let d = abs(dx) > abs(dy) ? dx : dy
            onScroll?(e.hasPreciseScrollingDeltas ? d : d * 6)
        }
    }
}
