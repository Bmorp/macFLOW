import SwiftUI
import AppKit

/// Where a widget is being drawn. Content adapts its colour treatment, never its layout.
enum WidgetStyle: Equatable {
    /// Full colour on the desktop, with its own background.
    case desktop
    /// Desaturated over a translucent background while you work in an app.
    case vibrant
    /// StandBy: no background, dark, larger.
    case standBy
    /// StandBy at night: everything in one dim red.
    case night

    var hasBackground: Bool { self == .desktop || self == .vibrant }
    var isAmbient: Bool { self == .standBy || self == .night }
}

private struct WidgetStyleKey: EnvironmentKey { static let defaultValue = WidgetStyle.desktop }
private struct WidgetFamilyKey: EnvironmentKey { static let defaultValue = WidgetFamily.small }

extension EnvironmentValues {
    var widgetStyle: WidgetStyle {
        get { self[WidgetStyleKey.self] }
        set { self[WidgetStyleKey.self] = newValue }
    }
    var widgetFamily: WidgetFamily {
        get { self[WidgetFamilyKey.self] }
        set { self[WidgetFamilyKey.self] = newValue }
    }
}

/// Widget geometry (`widgets.md › Specifications`): radius 22, margin 14, concentric content.
enum WidgetMetrics {
    static let radius: CGFloat = 22
    static let margin: CGFloat = 14
    /// What `ContainerRelativeShape` resolves to one margin in.
    static let innerRadius: CGFloat = radius - margin
    /// Transparent border around each widget window, for the lift and shadow while dragging.
    static let windowPadding: CGFloat = 16
}

/// Widget type scale — never below 11 pt (`typography.md`).
enum WidgetType {
    static let caption = Font.system(size: 11, weight: .semibold)
    static let captionNumeric = Font.system(size: 11, weight: .medium).monospacedDigit()
    static let body = Font.system(size: 13, weight: .medium)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let title = Font.system(size: 15, weight: .semibold)
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

enum WidgetPalette {
    /// StandBy night mode: one dim red, low enough not to light the room.
    static let night = Color(red: 0.6, green: 0.07, blue: 0.05)
}

/// The rounded container every desktop widget sits in. Handles full-colour ↔ vibrant
/// as a duo cross-fade of the two backgrounds, the edit badge and the drag lift.
struct WidgetContainer<Content: View>: View {
    let kind: WidgetKind
    let family: WidgetFamily
    var editing = false
    var lifted = false
    var onRemove: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @Environment(\.widgetStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WidgetMetrics.radius, style: .continuous)
        let vibrant = style == .vibrant
        ZStack(alignment: .topLeading) {
            ZStack {
                // Vibrant: the desktop shows through and content goes monochrome.
                VibrantBackdrop()
                    .opacity(vibrant ? 1 : 0)
                WidgetBackdrop(kind: kind)
                    .opacity(vibrant ? 0 : 1)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(vibrant ? 0.08 : 0.05), lineWidth: 0.5))

            content()
                .padding(WidgetMetrics.margin)
                .frame(width: family.size.width, height: family.size.height, alignment: .topLeading)
                .containerShape(RoundedRectangle(cornerRadius: WidgetMetrics.radius, style: .continuous))
                .saturation(vibrant ? 0 : 1)
                .opacity(vibrant ? 0.88 : 1)
                .environment(\.widgetFamily, family)

            if editing, let onRemove {
                RemoveBadge(action: onRemove)
                    .offset(x: -7, y: -7)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: family.size.width, height: family.size.height)
        .compositingGroup()
        .shadow(color: .black.opacity(vibrant ? 0.08 : (lifted ? 0.28 : 0.16)), radius: lifted ? 18 : 8, y: lifted ? 10 : 3)
        .scaleEffect(lifted ? 1.02 : 1)
        .animation(.smooth(duration: 0.5), value: vibrant)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: lifted)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: editing)
    }
}

/// The "–" badge shown on each widget while editing.
private struct RemoveBadge: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .scaleEffect(hover ? 1.1 : 1)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("Remove Widget")
        .help("Remove Widget")
    }
}

/// Translucent material sampling the desktop behind the window.
struct VibrantBackdrop: View {
    var body: some View {
        if RenderMode.snapshot {
            Color.primary.opacity(0.1)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: WidgetMetrics.radius))
        } else {
            VisualEffect(material: .hudWindow)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Shared widget pieces

/// A small caption row: glyph + title, in the widget's accent — as in the system widgets.
struct WidgetLabel: View {
    let title: String
    var symbol: String?
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(title.uppercased()).font(WidgetType.caption).tracking(0.3)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

/// An empty or permission state that invites the next action (`writing.md`).
struct WidgetPrompt: View {
    let symbol: String
    let message: String
    var action: String?
    var tint: Color = DS.Palette.blue
    var perform: (() -> Void)?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .small ? 6 : 8) {
            Image(systemName: symbol)
                .font(.system(size: family == .small ? 22 : 24, weight: .medium))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            Text(message)
                .font(WidgetType.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            if let action, let perform {
                Button(action: perform) {
                    Text(action)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(tint))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: 0.95))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The plain widget surface: white in Light, near-black grey in Dark, like the system widgets.
struct StandardBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        scheme == .dark ? Color(red: 0.118, green: 0.118, blue: 0.125) : Color.white
    }
}
