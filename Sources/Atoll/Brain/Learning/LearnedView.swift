import SwiftUI

/// Settings › Flow › What Flow learned. Every belief in a sentence, how sure Flow is, what it rests on, and a way to
/// make it forget. Below, how much of what Flow suggested you took over the last seven days: the number that should
/// go up as it learns.
struct WhatFlowLearnedSection: View {
    @State private var beliefs: [Belief] = []
    @State private var days: [Beliefs.Day] = []

    var body: some View {
        Section {
            if beliefs.isEmpty {
                Text("Nothing yet. Flow learns from what you take and wave away, and from what you tell it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(beliefs) { b in
                HStack(spacing: 10) {
                    Image(systemName: b.symbol).foregroundStyle(BrainStyle.tint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.sentence)
                        HStack(spacing: 8) {
                            ConfidenceBar(value: b.confidence)
                            Text("\(Self.sureness(b.confidence)) · from \(b.evidence)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        Beliefs.forget(b)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reload() }
                    } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Forget this")
                        .accessibilityLabel("Forget: \(b.sentence)")
                }
                .accessibilityElement(children: .combine)
            }
            if days.contains(where: { $0.reacted > 0 }) { trend }
        } header: {
            Text("What Flow Learned")
        } footer: {
            Text("Everything here was learned on this Mac, from your own reactions and answers. Forget one and Flow starts it over.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
    }

    private var trend: some View {
        let taken = days.reduce(0) { $0 + $1.accepted }, reacted = days.reduce(0) { $0 + $1.reacted }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Suggestions you took, last 7 days")
                Spacer()
                Text(reacted == 0 ? "—" : "\(Int((Double(taken) / Double(reacted) * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { d in
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(d.rate == nil ? Color.secondary.opacity(0.25) : BrainStyle.tint)
                            .frame(width: 14, height: max(3, 28 * (d.rate ?? 0)))
                        Text(d.day.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Suggestions you took over the last seven days")
        .accessibilityValue(reacted == 0 ? "None yet" : "\(taken) of \(reacted)")
    }

    private func reload() {
        beliefs = Beliefs.all()
        days = Beliefs.trend(BrainStore.shared.feedbackRows(since: Date().addingTimeInterval(-8 * 86_400)))
    }

    static func sureness(_ c: Double) -> String {
        c >= 0.75 ? "Sure" : c >= 0.4 ? "Fairly sure" : "Guessing"
    }
}

/// A thin bar for 0…1; the length says it, so it isn't only colour.
private struct ConfidenceBar: View {
    let value: Double
    var body: some View {
        Capsule().fill(Color.secondary.opacity(0.2))
            .frame(width: 56, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(BrainStyle.tint).frame(width: 56 * max(0.06, min(1, value)), height: 4)
            }
            .accessibilityHidden(true)
    }
}
