import SwiftUI

/// The island's Tasks place. Placeholder until the Flow Tasks stream lands; `height` and
/// `init(model:)` are the contract the island relies on.
struct TasksPlace: View {
    static let height: CGFloat = 320
    var model: IslandModel

    var body: some View {
        Text("Tasks")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
