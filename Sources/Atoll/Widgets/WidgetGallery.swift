import AppKit
import SwiftUI

extension WidgetKind {
    /// Gallery icon colour.
    var tint: Color {
        switch self {
        case .nowPlaying, .upNext: DS.Palette.red
        case .weather, .reminders: DS.Palette.blue
        case .worldClock: Color(white: 0.2)
        case .batteries: DS.Palette.green
        case .timer: DS.Palette.orange
        case .system: Color(white: 0.45)
        case .shortcuts, .shelf: DS.Palette.indigo
        }
    }
}

/// The widget gallery: pick a widget, see it live in every size, click to add it.
struct WidgetGalleryView: View {
    @State private var selection: WidgetKind = .nowPlaying
    @State private var query = ""
    @State private var justAdded: WidgetFamily?
    @FocusState private var searchFocused: Bool

    private var kinds: [WidgetKind] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? WidgetKind.allCases : WidgetKind.allCases.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(VisualEffect(material: .sidebar))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 880, height: 540)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Widgets", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = kinds.first { selection = first } }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            .padding(.top, 44)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(kinds) { k in
                        GalleryRow(kind: k, selected: k == selection) {
                            withAnimation(Motion.duo) { selection = k }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.title).font(.system(size: 22, weight: .bold))
                Text(selection.summary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .id(selection)
            .transition(.duo(anchor: .leading))
            .padding(.top, 40)

            HStack(alignment: .center, spacing: 28) {
                ForEach(selection.families) { family in
                    GalleryPreview(kind: selection, family: family, scale: previewScale, added: justAdded == family) {
                        add(family)
                    }
                }
            }
            .id(selection)
            .transition(.duo)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .center) {
                Text("Click a widget to add it. Drag widgets on the desktop to move them, or Control-click one to change its size.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Done") { WidgetManager.shared.endEditing() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
    }

    /// Previews as large as the detail pane allows, never above actual size.
    private var previewScale: CGFloat {
        let families = selection.families
        let width = families.reduce(0) { $0 + $1.size.width } + CGFloat(families.count - 1) * 28
        let height = families.map(\.size.height).max() ?? 170
        return min(0.9, 600 / width, 330 / height)
    }

    private func add(_ family: WidgetFamily) {
        WidgetStore.shared.add(selection, family: family)
        Haptics.confirm()
        withAnimation(Motion.duo) { justAdded = family }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(Motion.duo) { if justAdded == family { justAdded = nil } }
        }
    }
}

private struct GalleryRow: View {
    let kind: WidgetKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind.tint.gradient))
                Text(kind.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GalleryPreview: View {
    let kind: WidgetKind
    let family: WidgetFamily
    let scale: CGFloat
    let added: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                ZStack(alignment: .topLeading) {
                    WidgetContainer(kind: kind, family: family) { WidgetContent(kind: kind) }
                        .environment(\.widgetStyle, .desktop)
                        .allowsHitTesting(false)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: family.size.width * scale, height: family.size.height * scale, alignment: .topLeading)
                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, added ? DS.Palette.green : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .background(Circle().fill(.white).padding(3))
                        .offset(x: -9, y: -9)
                        .opacity(hover || added ? 1 : 0)
                        .scaleEffect(hover || added ? 1 : 0.6)
                }
                .scaleEffect(hover ? 1.03 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.96))
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
            .accessibilityLabel("Add \(family.label) \(kind.title) widget")
            Text(added ? "Added" : family.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(added ? DS.Palette.green : .secondary)
                .contentTransition(.opacity)
        }
    }
}

/// The gallery's window. Closing it ends editing.
@MainActor
final class WidgetGalleryWindow: NSObject, NSWindowDelegate {
    static let shared = WidgetGalleryWindow()
    private var window: NSWindow?
    private var closing = false

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Widgets"
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.delegate = self
            w.contentView = NSHostingView(rootView: WidgetGalleryView())
            if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: vf.midX - 440, y: vf.minY + 48))
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let window, window.isVisible, !closing else { return }
        closing = true
        window.close()
        closing = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        WidgetManager.shared.endEditing()
    }
}
