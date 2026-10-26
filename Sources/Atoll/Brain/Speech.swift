import AppKit
import AVFoundation
import CoreAudio
import Speech

/// Speech to text, on this Mac only (`requiresOnDeviceRecognition`): nothing you say is sent anywhere.
/// Feeds buffers from any source (the microphone, the Mac's own audio) and reports the running text. Long sessions
/// roll over to a fresh request every 50 seconds — committing what was heard — so a meeting can run for an hour.
final class LiveTranscriber: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed: [String] = []
    private var partial = ""
    private var generation = 0
    /// Cumulative text so far, on the main queue.
    var onText: ((String) -> Void)?
    /// A finished stretch of speech (a rollover or a pause long enough to end a result), on the main queue.
    var onSegment: ((String) -> Void)?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    var isAvailable: Bool { recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return (committed + (partial.isEmpty ? [] : [partial])).joined(separator: " ")
    }

    func begin() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        lock.lock()
        generation += 1
        let gen = generation
        request = req
        lock.unlock()
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, let result else { return }
            let heard = result.bestTranscription.formattedString
            self.lock.lock()
            let current = gen == self.generation
            if current { self.partial = heard }
            self.lock.unlock()
            if result.isFinal, !heard.isEmpty {
                self.commit(heard, wasCurrent: current)
            } else if current {
                let all = self.text
                DispatchQueue.main.async { self.onText?(all) }
            }
            _ = error
        }
        lock.lock(); task = t; lock.unlock()
    }

    private func commit(_ heard: String, wasCurrent: Bool) {
        lock.lock()
        committed.append(heard)
        if wasCurrent { partial = "" }
        let all = (committed + (partial.isEmpty ? [] : [partial])).joined(separator: " ")
        lock.unlock()
        DispatchQueue.main.async {
            self.onSegment?(heard)
            self.onText?(all)
        }
    }

    /// Called from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }

    /// Ends this request (its final result still arrives) and starts another, so nothing is cut off.
    func rollover() {
        lock.lock(); let old = request; lock.unlock()
        begin()
        old?.endAudio()
    }

    /// No more audio; the final result arrives through `onSegment`/`onText`.
    func end() {
        lock.lock(); let r = request; request = nil; lock.unlock()
        r?.endAudio()
    }

    func cancel() {
        lock.lock(); let t = task; request = nil; task = nil; lock.unlock()
        t?.cancel()
    }

    /// Speech recognition and microphone permission, asked once each; `completion(true)` when both are allowed.
    static func authorize(microphone: Bool, _ completion: @escaping @MainActor (Bool) -> Void) {
        func micThen() {
            guard microphone else { DispatchQueue.main.async { completion(true) }; return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: DispatchQueue.main.async { completion(true) }
            case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok) } }
            default: DispatchQueue.main.async { completion(false) }
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: micThen()
        case .notDetermined: SFSpeechRecognizer.requestAuthorization { s in if s == .authorized { micThen() } else { DispatchQueue.main.async { completion(false) } } }
        default: DispatchQueue.main.async { completion(false) }
        }
    }
}

/// The microphone, as buffers (and a level for the waveform).
final class MicrophoneInput: @unchecked Sendable {
    private lazy var engine = AVAudioEngine()
    private(set) var running = false

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer, Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer, Self.level(buffer))
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(1, n / 4)))
        return min(1, rms * 12)
    }
}

// MARK: - Hold the notch and talk

/// Press and hold the notch, say what you want, let go: Flow does it. Listening shows in Flow's conversation
/// (live words and a level meter); letting go hands the words to Flow as if you'd typed them.
@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()

    enum State: Equatable { case idle, listening, finishing, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0

    /// Made on first use: an audio engine shouldn't exist until someone talks.
    private lazy var mic = MicrophoneInput()
    private var transcriber: LiveTranscriber?
    private var releasedEarly = false
    private var authorizing = false

    var isActive: Bool { state == .listening || state == .finishing }

    /// The press crossed the hold threshold.
    func begin(on model: IslandModel) {
        guard Prefs.shared.holdToTalk, !isActive, !authorizing else { return }
        releasedEarly = false
        transcript = ""
        model.openBrain()
        Haptics.snap()
        authorizing = true
        LiveTranscriber.authorize(microphone: true) { [weak self] ok in
            guard let self else { return }
            self.authorizing = false
            guard ok else {
                self.state = .failed("Allow Microphone and Speech Recognition for Mac Flow in System Settings › Privacy & Security.")
                return
            }
            // Asking for permission can outlast the press: if you've let go already, don't start listening.
            guard !self.releasedEarly else { self.state = .idle; return }
            self.listen()
        }
    }

    private func listen() {
        let t = LiveTranscriber()
        guard t.isAvailable else {
            state = .failed("On-device speech isn’t ready. Turn on Dictation in System Settings › Keyboard to download it.")
            return
        }
        t.onText = { [weak self] text in self?.transcript = text }
        t.begin()
        transcriber = t
        do {
            try mic.start { buffer, level in
                t.append(buffer)
                DispatchQueue.main.async { VoiceInput.shared.level = level }
            }
            state = .listening
        } catch {
            t.cancel()
            transcriber = nil
            state = .failed("The microphone couldn’t start.")
        }
    }

    /// Let go: stop listening, wait a beat for the last words, hand them to Flow.
    func finish() {
        guard state == .listening else {
            releasedEarly = true
            return
        }
        state = .finishing
        mic.stop()
        level = 0
        transcriber?.end()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let text = (self.transcriber?.text ?? self.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
            self.transcriber?.cancel()
            self.transcriber = nil
            self.state = .idle
            self.transcript = ""
            if text.count >= 2 { BrainAgent.shared.send(text) }
        }
    }

    func cancel() {
        mic.stop()
        transcriber?.cancel()
        transcriber = nil
        state = .idle
        transcript = ""
        level = 0
    }

    func clearFailure() { if case .failed = state { state = .idle } }

    #if DEBUG
    func debugSet(state s: State, transcript t: String, level l: Float) { state = s; transcript = t; level = l }
    #endif
}

// MARK: - The Mac's own audio (the other side of a call)

/// Everything the Mac plays — in a call, the other people — captured through a Core Audio process tap
/// (macOS 14.2+; asks "System Audio Recording" permission once). Mac Flow's own sounds are left out.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "atoll.audiotap", qos: .userInitiated)

    enum TapError: Error { case failed(String, OSStatus) }

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { throw TapError.failed("tap", err) }

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { stop(); throw TapError.failed("format", err) }

        guard let outputUID = Self.defaultOutputUID() else { stop(); throw TapError.failed("output", -1) }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Flow Notes",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard err == noErr else { stop(); throw TapError.failed("aggregate", err) }

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            // The buffer list is only valid during the callback: copy it before it travels.
            guard let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let copy = Self.copy(view) else { return }
            onBuffer(copy)
        }
        guard err == noErr else { stop(); throw TapError.failed("ioproc", err) }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { stop(); throw TapError.failed("start", err) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard src.frameLength > 0, let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        dst.frameLength = src.frameLength
        let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
        let d = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        for (a, b) in zip(s, d) {
            guard let from = a.mData, let to = b.mData else { continue }
            memcpy(to, from, Int(min(a.mDataByteSize, b.mDataByteSize)))
        }
        return dst
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Mac Flow's own Core Audio process object, so its sounds aren't transcribed.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return err == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
