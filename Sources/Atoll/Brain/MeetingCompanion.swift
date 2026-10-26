import AppKit
import Combine
import SwiftUI

/// The meeting companion. While you're in a meeting the island shows how long is left and the agenda; if you start
/// notes (each meeting, by choice — and the island shows a red dot the whole time), it transcribes on this Mac:
/// you from the microphone, the others from the Mac's own audio. When the meeting ends Flow writes it up — a short
/// summary and the action items — saves the notes, and offers to carry the action items into tomorrow's plan.
/// Audio is never saved or sent anywhere.
@MainActor
final class MeetingCompanion: ObservableObject {
    static let shared = MeetingCompanion()

    enum Speaker: String, Codable { case you = "You", them = "Them" }
    struct Line: Identifiable, Equatable, Codable {
        var id = UUID()
        let speaker: Speaker
        let text: String
        let at: Date
    }
    enum State: Equatable { case idle, consenting, recording, wrapping, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [Line] = []
    /// What's being said right now, per side (the tail of the live text).
    @Published private(set) var live: [Speaker: String] = [:]
    @Published private(set) var startedAt: Date?
    @Published private(set) var title = ""
    /// Only the microphone could be heard (System Audio Recording not allowed).
    @Published private(set) var oneSided = false
    @Published private(set) var lastNotes: URL?

    private lazy var mic = MicrophoneInput()
    private var tap: AnyObject?
    private var you: LiveTranscriber?
    private var them: LiveTranscriber?
    private var rollover: Timer?
    private var callEnded: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init() {
        ActivityCenter.shared.$call
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] onCall in self?.callChanged(onCall) }
            .store(in: &cancellables)
    }

    /// The meeting on now, from the calendar.
    var event: CalendarModel.Event? { CalendarModel.shared.events.first { $0.isNow && !$0.isAllDay } }

    var isRecording: Bool { state == .recording }

    /// Whether the island's call or meeting row grows the companion strip.
    var showsStrip: Bool { state != .idle || event != nil || (Prefs.shared.meetingNotes && ActivityCenter.shared.call != nil) }

    // MARK: Starting

    /// "Take Notes": first a word about consent, then `begin`.
    func offer() {
        guard state == .idle || state.isFailure else { return }
        withAnimation(Motion.morph) { state = .consenting }
    }

    func cancelOffer() { if state == .consenting { withAnimation(Motion.morph) { state = .idle } } }

    func begin() {
        guard state == .idle || state == .consenting || state.isFailure else { return }
        LiveTranscriber.authorize(microphone: true) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.state = .failed("Allow Microphone and Speech Recognition for Mac Flow in System Settings.")
                return
            }
            self.record()
        }
    }

    private func record() {
        let mine = LiveTranscriber(), theirs = LiveTranscriber()
        guard mine.isAvailable else {
            state = .failed("On-device speech isn’t ready — turn on Dictation in System Settings › Keyboard.")
            return
        }
        lines = []
        live = [:]
        title = event?.title ?? ActivityCenter.shared.call.map { "Call in \($0.app.name)" } ?? "Meeting"
        for (t, side) in [(mine, Speaker.you), (theirs, Speaker.them)] {
            t.onSegment = { [weak self] text in self?.heard(text, from: side) }
            t.onText = { [weak self] text in self?.live[side] = String(text.suffix(140)) }
            t.begin()
        }
        you = mine
        them = theirs
        do {
            try mic.start { buffer, _ in mine.append(buffer) }
        } catch {
            stopAudio()
            state = .failed("The microphone couldn’t start.")
            return
        }
        oneSided = true
        if #available(macOS 14.2, *) {
            let t = SystemAudioTap()
            if (try? t.start({ theirs.append($0) })) != nil {
                tap = t
                oneSided = false
            }
        }
        let r = Timer(timeInterval: 50, repeats: true) { _ in
            MainActor.assumeIsolated {
                MeetingCompanion.shared.you?.rollover()
                MeetingCompanion.shared.them?.rollover()
            }
        }
        RunLoop.main.add(r, forMode: .common)
        rollover = r
        startedAt = Date()
        withAnimation(Motion.morph) { state = .recording }
        Haptics.confirm()
    }

    private func heard(_ text: String, from side: Speaker) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lines.append(Line(speaker: side, text: t, at: Date()))
    }

    // MARK: Stopping

    func stop() {
        guard state == .recording else { return }
        stopAudio(keepTranscribers: true)
        withAnimation(Motion.morph) { state = .wrapping }
        // The last words arrive a moment after the audio stops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            self.you?.cancel()
            self.them?.cancel()
            self.you = nil
            self.them = nil
            self.live = [:]
            Task { await self.wrapUp() }
        }
    }

    private func stopAudio(keepTranscribers: Bool = false) {
        rollover?.invalidate()
        rollover = nil
        mic.stop()
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
        you?.end()
        them?.end()
        if !keepTranscribers {
            you?.cancel(); them?.cancel()
            you = nil; them = nil
        }
    }

    /// The call ended: notes stop on their own a little after (a dropped connection gets a moment to come back).
    private func callChanged(_ onCall: Bool) {
        callEnded?.cancel()
        guard !onCall, state == .recording, event == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, ActivityCenter.shared.call == nil else { return }
            self.stop()
        }
        callEnded = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    }

    // MARK: Writing it up

    private func wrapUp() async {
        let transcript = lines.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        guard !transcript.isEmpty else {
            withAnimation(Motion.morph) { state = .failed("Nothing was heard, so there are no notes.") }
            return
        }
        var summary = ""
        var actions: [String] = []
        if let written = await Mind.shared.meetingNotes(transcript, title: title) {
            summary = written.summary
            actions = written.actions
        }
        if actions.isEmpty { actions = Self.actionItems(from: lines.map(\.text)) }
        let url = save(transcript: transcript, summary: summary, actions: actions)
        lastNotes = url
        Memory.shared.remember([(id: "meeting.\(Int((startedAt ?? Date()).timeIntervalSince1970))", date: startedAt ?? Date(), kind: "meeting",
                                 text: "Meeting “\(title)”: \(summary.isEmpty ? lines.prefix(6).map(\.text).joined(separator: " ") : summary)"
                                     + (actions.isEmpty ? "" : " Action items: " + actions.joined(separator: "; ")))])
        if !summary.isEmpty { BrainStore.shared.setFact("meeting:last", "\(title) (\(Date().formatted(date: .abbreviated, time: .shortened))): \(summary)", source: "inferred", confidence: 1) }
        let first = actions.first.map { "“\($0)”" + (actions.count > 1 ? " +\(actions.count - 1)" : "") } ?? (summary.isEmpty ? "Transcript saved" : summary)
        FlowInbox.shared.suggest(BrainSuggestion(kind: "meeting.notes", symbol: "list.bullet.clipboard",
                                                 title: actions.isEmpty ? "Notes from \(title)" : "\(title): \(actions.count) action item\(actions.count == 1 ? "" : "s")",
                                                 detail: first + " · notes saved",
                                                 actionTitle: actions.isEmpty ? "Open Notes" : "Add to Tomorrow",
                                                 action: actions.isEmpty ? .openFile(url) : .addToTomorrow(actions, from: "From \(title)"),
                                                 confidence: 0.9), lasts: 12 * 3600)
        withAnimation(Motion.morph) { state = .idle }
    }

    /// Notes as Markdown, in Mac Flow's folder: title, time, summary, action items, then the transcript.
    private func save(transcript: String, summary: String, actions: [String]) -> URL {
        let dir = Storage.directory.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = startedAt ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let safe = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(60)
        let url = dir.appendingPathComponent("\(f.string(from: start)) \(safe).md")
        var md = "# \(title)\n\n\(start.formatted(date: .complete, time: .shortened)) · \(Int(Date().timeIntervalSince(start) / 60)) min"
        md += oneSided ? " · your side only\n\n" : "\n\n"
        if !summary.isEmpty { md += "## Summary\n\n\(summary)\n\n" }
        if !actions.isEmpty { md += "## Action items\n\n" + actions.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n" }
        md += "## Transcript\n\n" + transcript.replacingOccurrences(of: "\n", with: "\n\n") + "\n"
        try? md.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Without the on-device model: sentences that commit someone to something.
    nonisolated static func actionItems(from texts: [String]) -> [String] {
        let cues = ["i'll ", "i will ", "we'll ", "we will ", "let's ", "action item", "follow up", "follow-up", "can you ", "could you ",
                    "please send", "i need to ", "we need to ", "by tomorrow", "by friday", "next week", "todo", "to-do"]
        var out: [String] = []
        for text in texts {
            for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
                let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = s.lowercased()
                guard s.count >= 12, s.count <= 140, cues.contains(where: { lower.contains($0) }) else { continue }
                let item = s.prefix(1).uppercased() + s.dropFirst()
                if !out.contains(item) { out.append(item) }
                if out.count >= 5 { return out }
            }
        }
        return out
    }

    #if DEBUG
    func debugSet(state s: State, lines l: [Line], title t: String) {
        state = s; lines = l; title = t; startedAt = Date().addingTimeInterval(-754)
        live = [.them: l.last(where: { $0.speaker == .them })?.text ?? ""]
    }
    #endif
}

extension MeetingCompanion.State {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

// MARK: - The strip under a call or meeting

/// Time left and the agenda; and the notes — offer, consent, recording (with what's being said), writing up.
struct MeetingCompanionStrip: View {
    var model: IslandModel
    @ObservedObject private var companion = MeetingCompanion.shared
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.islandShowing) private var showing

    static let height: CGFloat = 52

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch companion.state {
            case .consenting: consent
            case .recording: recording
            case .wrapping:
                ThinkingDots(size: 20)
                Text("Writing up the notes…").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                Spacer(minLength: 0)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(DS.Palette.orange)
                Text(message).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Ghost(symbol: "xmark", label: "Dismiss", size: 9, tint: DS.Ink.tertiary, hit: 22) { companion.cancelOffer(); companion.dismissFailure() }
            case .idle: overview
            }
        }
        .padding(.horizontal, IslandModel.expandedFlare + DS.Island.rowLeading + 2)
        .frame(height: Self.height)
        .overlay(alignment: .top) { Rectangle().fill(DS.Ink.hairline).frame(height: 1).padding(.horizontal, IslandModel.expandedFlare + 14) }
    }

    /// Before notes: how long is left, and the agenda's first lines.
    private var overview: some View {
        Group {
            if let e = companion.event {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let left = max(0, Int(e.end.timeIntervalSince(ctx.date) / 60))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(left)").font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(DS.Ink.primary)
                        Text("MIN LEFT").font(.system(size: 8.5, weight: .bold)).tracking(0.6).foregroundStyle(DS.Ink.tertiary)
                    }
                    .frame(width: 52, alignment: .leading)
                }
                Text(e.notes.map { $0.replacingOccurrences(of: "\n", with: " · ") } ?? "No agenda in the invite")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(e.notes == nil ? DS.Ink.tertiary : DS.Ink.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Notes are transcribed on this Mac and written up when the call ends.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.tertiary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if prefs.meetingNotes {
                FlowOptionButton(title: "Take Notes") { companion.offer() }
            }
        }
    }

    private var consent: some View {
        Group {
            Image(systemName: "waveform.badge.mic").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Palette.red)
            Text("Transcribed on this Mac. Let everyone know you’re taking notes.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            QuietButton(title: "Cancel") { companion.cancelOffer() }
            FlowOptionButton(title: "Start Notes", prominent: true) { companion.begin() }
        }
    }

    private var recording: some View {
        Group {
            HStack(spacing: 6) {
                LiveDot(color: DS.Palette.red, size: 6)
                TimelineView(PeriodicTimelineSchedule.seconds(showing)) { ctx in
                    Text(companion.startedAt.map { max(0, ctx.date.timeIntervalSince($0)).clock } ?? "")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(DS.Ink.primary)
                }
            }
            .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let them = companion.live[.them], !them.isEmpty {
                    Text(them).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1).truncationMode(.head)
                }
                if let me = companion.live[.you], !me.isEmpty {
                    Text("You: " + me).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.tertiary).lineLimit(1).truncationMode(.head)
                }
                if (companion.live[.them] ?? "").isEmpty && (companion.live[.you] ?? "").isEmpty {
                    Text(companion.oneSided ? "Listening — your side only" : "Listening").font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FlowOptionButton(title: "Stop") { companion.stop() }
        }
    }
}

extension MeetingCompanion {
    func dismissFailure() { if state.isFailure { withAnimation(Motion.morph) { state = .idle } } }
}
