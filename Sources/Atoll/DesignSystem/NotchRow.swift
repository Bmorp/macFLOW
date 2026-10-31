import SwiftUI

extension IslandModel {
    /// The width a place's top row can use on each side of the notch. The camera covers the middle of that row (the
    /// island is centred on it), so each side gets half of what's left of the island's width, less its inset and a gap.
    func wing(for place: IslandFocus, inset: CGFloat, gap: CGFloat = 8) -> CGFloat {
        max(0, (expandedSize(place).width - notch.width) / 2 - inset - gap)
    }
}

/// A place's top row: what sits left of the notch and what sits right of it, each held to the width the camera
/// leaves visible, so nothing ever slides underneath. Content that can be wider offers smaller forms through
/// `ViewThatFits`; the row picks the fullest that fits.
struct NotchRow<Leading: View, Trailing: View>: View {
    var model: IslandModel
    var place: IslandFocus
    var inset: CGFloat
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let wing = model.wing(for: place, inset: inset)
        HStack(spacing: 0) {
            leading().frame(width: wing, alignment: .leading)
            Spacer(minLength: 0)
            trailing().frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(height: model.notch.height)
    }
}

/// The island's segmented control: a capsule of choices beside the notch (Today · Upcoming · Someday).
/// It comes in four fits (full labels; tighter labels; the chosen one named and the rest as symbols; symbols alone,
/// with names as tooltips) so the row it sits in can choose the fullest that fits.
struct SegmentPill<Item: Hashable>: View {
    enum Fit { case full, tight, named, symbols }

    let items: [Item]
    let selection: Item
    var fit: Fit = .full
    let title: (Item) -> String
    let symbol: (Item) -> String
    var marked: (Item) -> Bool = { _ in false }
    let select: (Item) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button { select(item) } label: {
                    HStack(spacing: 4) {
                        switch fit {
                        case .symbols:
                            Image(systemName: symbol(item)).font(.system(size: 11, weight: .semibold))
                        case .named:
                            Image(systemName: symbol(item)).font(.system(size: 11, weight: .semibold))
                            if on { Text(title(item)).font(.system(size: 11.5, weight: .semibold)) }
                        case .full, .tight:
                            Text(title(item)).font(.system(size: fit == .full ? 11.5 : 11, weight: .semibold))
                        }
                        if marked(item) { Circle().fill(BrainStyle.tint).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(on ? Color.black : DS.Ink.secondary)
                    .padding(.horizontal, fit == .full ? 10 : fit == .tight ? 7 : 8)
                    .frame(height: 22)
                    .background(Capsule().fill(on ? Color.white : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(title(item))
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .fixedSize()
    }
}
