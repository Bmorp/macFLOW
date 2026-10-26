import SwiftUI
import CoreAudio
import UniformTypeIdentifiers

/// Transient alerts: a wide compact for status changes, a brief one-row card for things you can act on.
struct AlertView: View {
    var model: IslandModel
    /// Captured when shown, so the alert keeps its content while it leaves.
    let alert: AlertState
    let ns: Namespace.ID
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        if alert.kind.isWide { wide(alert.kind) } else { card(alert.kind) }
    }

    // MARK: Wide compact

    private func wide(_ kind: IslandAlert) -> some View {
        CompactLayout(notch: model.notch, wing: IslandModel.wideAlertWing) {
            HStack(spacing: 7) {
                wideLeading(kind)
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.Space.m)
        } trailing: {
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                wideTrailing(kind)
            }
            .padding(.trailing, DS.Space.m)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.Palette.label)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func wideLeading(_ kind: IslandAlert) -> some View {
        switch kind {
        case .volume(let level, let muted):
            // On AirPods or another output, show the device: you always know where the sound is going.
            if let out = AudioDevices.shared.currentOutput, out.transport != kAudioDeviceTransportTypeBuiltIn {
                Image(systemName: out.symbol).frame(width: 22, alignment: .leading)
            } else {
                Image(systemName: Self.volumeSymbol(level, muted))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, alignment: .leading)
            }
        case .brightness(let level):
            Image(systemName: level < 0.33 ? "sun.min.fill" : "sun.max.fill")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, alignment: .leading)
        case .charging:
            Image(systemName: "bolt.fill").foregroundStyle(DS.Palette.green)
            Text("Charging").foregroundStyle(DS.Palette.secondary)
        case .lowBattery:
            Image(systemName: "battery.25percent").foregroundStyle(DS.Palette.red)
            Text("Low Battery").foregroundStyle(DS.Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
        case .privacy(let camera, _):
            Image(systemName: camera ? "video.fill" : "mic.fill").foregroundStyle(camera ? DS.Palette.green : DS.Palette.orange)
            Text(camera ? "Camera" : "Microphone").foregroundStyle(DS.Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
        case .message(let symbol, _, let tint):
            Image(systemName: symbol).foregroundStyle(tint)
        case .device(let d):
            Image(systemName: d.symbol).foregroundStyle(d.connected ? DS.Palette.label : DS.Palette.secondary)
            Text(d.connected ? "Connected" : "Disconnected").foregroundStyle(DS.Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func wideTrailing(_ kind: IslandAlert) -> some View {
        switch kind {
        case .volume(let level, let muted):
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.track)
                Capsule().fill(.white).frame(width: 76 * (muted ? 0 : level))
            }
            .frame(width: 76, height: 6)
            .animation(.snappy, value: level)
            .accessibilityLabel("Volume \(muted ? 0 : Int(level * 100)) percent")
        case .brightness(let level):
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.track)
                Capsule().fill(.white).frame(width: max(6, 76 * level))
            }
            .frame(width: 76, height: 6)
            .animation(.snappy, value: level)
            .accessibilityLabel("Brightness \(Int(level * 100)) percent")
        case .charging(let level):
            Text("\(level)%").monospacedDigit().foregroundStyle(DS.Palette.green)
            BatteryGlyph(level: level, charging: true, width: 24)
        case .lowBattery(let level):
            Text("\(level)%").monospacedDigit().foregroundStyle(DS.Palette.red)
            BatteryGlyph(level: level, charging: false, width: 24)
        case .privacy(_, let app):
            Text(app ?? "In Use").foregroundStyle(DS.Palette.label).lineLimit(1).minimumScaleFactor(0.7)
        case .message(_, let text, _):
            Text(text).lineLimit(1).minimumScaleFactor(0.75)
        case .device(let d):
            Text(d.name).lineLimit(1).minimumScaleFactor(0.7)
        default:
            EmptyView()
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60), s = Int(t) % 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    static func volumeSymbol(_ level: Double, _ muted: Bool) -> String {
        if muted || level < 0.01 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: One-row cards

    @ViewBuilder
    private func card(_ kind: IslandAlert) -> some View {
        switch kind {
        case .trackChanged:
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    Artwork(image: media.artwork, size: 40, radius: 9, accent: media.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        MarqueeText(text: media.title, font: DS.Kit.title, color: DS.Ink.primary)
                        Text(media.artist).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Waveform(tint: DS.Ink.secondary, active: media.isPlaying, bars: 5, height: 16, barWidth: 2.5)
                }
            }

        case .timerFinished(let label):
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "\(label) finished", dot: DS.Palette.orange)
                        Text("Time’s up").font(DS.Kit.titleLarge).foregroundStyle(DS.Ink.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Ghost(symbol: "xmark", label: "Dismiss", size: 11, tint: DS.Ink.tertiary, hit: 28) { model.dismissAlert() }
                    Pill(title: "5-Min Break") {
                        FocusTimer.shared.start(minutes: 5, label: "Break")
                        model.dismissAlert()
                    }
                }
            }

        case .meetingSoon(let event, _):
            MeetingPresentation.Expanded(model: model, event: event)

        case .claudeFinished(let id, let name, let duration):
            claudeCard(id: id, eyebrow: "Finished · \(Self.duration(duration))", title: name, waiting: false)

        case .claudeNeedsYou(let id, let name, let folder):
            claudeCard(id: id, eyebrow: "Needs you · \(folder)", title: name, waiting: true)

        case .brainSuggestion(let s):
            BrainSuggestionCard(model: model, suggestion: s)

        case .brainQuestion(let q):
            BrainQuestionCard(model: model, question: q)

        case .lens(let item):
            LensCard(model: model, item: item)

        case .learn(let card):
            StudyCardView(model: model, card: card)

        case .tip(_, let title, let detail, let step, let total):
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(DS.Kit.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        Text(detail).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(step + 1) / \(total)").font(DS.Kit.meta).foregroundStyle(DS.Ink.tertiary)
                    Pill(title: step + 1 < total ? "Next" : "Done") { IslandManager.shared.advanceTour() }
                }
            }

        case .downloadFinished(let url):
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    IconImage(image: IconCache.file(url.path), size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Downloaded", dot: DS.Palette.blue)
                        Text(url.lastPathComponent).font(DS.Kit.title).foregroundStyle(DS.Ink.primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Ghost(symbol: "folder", label: "Show in Finder", size: 14, tint: DS.Ink.secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        model.dismissAlert()
                    }
                    Pill(title: "Open") {
                        NSWorkspace.shared.open(url)
                        model.dismissAlert()
                    }
                }
            }

        case .device(let d):
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    Image(systemName: d.symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(DS.Ink.primary).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: d.connected ? "Connected" : "Disconnected", dot: d.connected ? DS.Palette.green : nil)
                        Text(d.name).font(DS.Kit.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 18) {
                        if let l = d.left { level(l, "L") }
                        if let r = d.right { level(r, "R") }
                        if let c = d.caseLevel { level(c, "Case") }
                        if d.left == nil, d.right == nil, let s = d.single { level(s, "") }
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    // MARK: Pieces

    /// A battery level as a figure with a hairline beneath — the level is the instrument.
    private func level(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Figure(value: "\(value)", size: 22, tint: value <= 15 ? DS.Palette.red : DS.Ink.primary)
                if !label.isEmpty { Text(label).font(DS.Kit.eyebrow).foregroundStyle(DS.Ink.tertiary) }
            }
            Capsule().fill(DS.Ink.well).frame(width: 34, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(value <= 15 ? DS.Palette.red : DS.Palette.green).frame(width: 34 * CGFloat(value) / 100, height: 3)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.isEmpty ? "Battery" : label) \(value) percent")
    }

    private func claudeCard(id: String, eyebrow: String, title: String, waiting: Bool) -> some View {
        Instrument(notch: model.notch, width: model.expandedWidth) {
            HStack(spacing: 14) {
                ClaudeGlyph(size: 26, spinning: false)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: eyebrow, dot: waiting ? ClaudeSessions.tint : DS.Palette.green, tint: waiting ? ClaudeSessions.tint : DS.Ink.tertiary)
                    Text(title).font(DS.Kit.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Pill(title: "Open") {
                    ClaudeSessions.shared.open(ClaudeSessions.shared.sessions.first { $0.id == id })
                    model.dismissAlert()
                }
            }
        }
    }
}
