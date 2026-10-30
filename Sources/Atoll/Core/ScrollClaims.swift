import SwiftUI

/// Content inside the open island that scrolls sideways itself (the Home carousel, a timer you nudge, a task row you
/// swipe) claims sideways scrolls while the pointer is over it, so the island doesn't also switch places.
/// The island reads `horizontal` before it treats a sideways scroll as a tab move; vertical scrolls stay the island's.
@MainActor
enum ScrollClaims {
    private static var claims: Set<String> = []

    /// Whether something under the pointer is handling sideways scrolls.
    static var horizontal: Bool { !claims.isEmpty }

    static func set(_ id: String, _ claiming: Bool) {
        if claiming { claims.insert(id) } else { claims.remove(id) }
    }
}

extension View {
    /// Claims sideways scrolls while the pointer is over this view.
    func claimsHorizontalScroll(_ id: String) -> some View {
        onHover { ScrollClaims.set(id, $0) }
            .onDisappear { ScrollClaims.set(id, false) }
    }
}
