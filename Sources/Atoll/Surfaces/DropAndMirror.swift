import SwiftUI
import UniformTypeIdentifiers

/// While a file is dragged to the notch, the island becomes two targets.
struct DropView: View {
    var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            HStack(spacing: DS.Space.m) {
                DropTile(model: model, target: .shelf, symbol: "tray.and.arrow.down.fill", title: "Hold on Shelf",
                         detail: "Drag out anytime", tint: DS.Palette.cyan)
                    .islandReveal(0)
                DropTile(model: model, target: .airdrop, symbol: "dot.radiowaves.left.and.right", title: "AirDrop",
                         detail: "To nearby devices", tint: DS.Palette.blue)
                    .islandReveal(1)
                DropTile(model: model, target: .flow, symbol: "sparkles", title: "Ask Flow",
                         detail: "Summary, tasks, dates", tint: BrainStyle.tint)
                    .islandReveal(2)
            }
            .padding(.horizontal, IslandModel.expandedFlare + 14)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(height: IslandModel.dropRowHeight)
        }
        .frame(width: model.expandedWidth, alignment: .top)
    }
}

private struct DropTile: View {
    var model: IslandModel
    let target: DropTarget
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    @State private var targeted = false

    var body: some View {
        // Stacked — icon, name, what it does — so three fit side by side without cutting a word.
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(targeted ? Color.white : tint)
                .symbolEffect(.bounce, value: targeted)
                .frame(height: 22)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Palette.label).lineLimit(1)
            Text(detail).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DS.Palette.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(targeted ? tint.opacity(0.35) : DS.Palette.fill.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? tint : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [5, 4]))
        )
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(Motion.hover, value: targeted)
        .modifier(DropTargetModifier(enabled: !RenderMode.snapshot, targeted: $targeted) { providers in
            model.handleDrop(providers, target: target)
        })
        .onChange(of: targeted) { _, on in
            if on { model.dropTarget = target } else if model.dropTarget == target { model.dropTarget = nil }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DropTargetModifier: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: $targeted, perform: perform)
        } else {
            content
        }
    }
}

/// A live camera preview for checking yourself before a call.
struct MirrorView: View {
    var model: IslandModel
    @ObservedObject private var camera = CameraMirror.shared

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.Palette.fill.opacity(0.5))
                    switch camera.state {
                    case .running:
                        if RenderMode.snapshot {
                            Color.gray.opacity(0.3)
                        } else {
                            CameraPreview(session: camera.session)
                                .scaleEffect(x: -1, y: 1)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    case .requesting, .idle:
                        ProgressView().controlSize(.small)
                    case .denied:
                        notice("Camera access is off.", action: "Open Privacy Settings") { camera.openPrivacySettings() }
                    case .unavailable:
                        notice("No camera is available.", action: nil) {}
                    }
                }
                .animation(.smooth, value: camera.state)
                RowDisc(symbol: "xmark", label: "Close Mirror", fill: 0.3, diameter: 28) { model.collapse() }
                    .padding(10)
            }
            .islandReveal(0)
            .padding(.horizontal, IslandModel.expandedFlare + 12)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(height: IslandModel.mirrorRowHeight)
        }
        .frame(width: model.expandedWidth, alignment: .top)
    }

    private func notice(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "video.slash.fill").font(.system(size: 22)).foregroundStyle(DS.Palette.secondary)
            Text(text).font(DS.Typeface.body).foregroundStyle(DS.Palette.secondary)
            if let action { SecondaryButton(title: action, action: perform) }
        }
    }
}
