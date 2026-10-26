@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// "Check yourself before the call" — a live front-camera mirror inside the island.
@MainActor
final class CameraMirror: ObservableObject {
    static let shared = CameraMirror()

    enum State: Equatable { case idle, requesting, running, denied, unavailable }

    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "atoll.camera")
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            state = .requesting
            NSApp.activate()
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { CameraMirror.shared.run() } else { CameraMirror.shared.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        guard state == .running || state == .requesting else { return }
        let s = session
        queue.async { s.stopRunning() }
        state = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AudioActivity.shared.suppressCamera = false
            AudioActivity.shared.refreshCamera()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func run() {
        if !configured, !configure() { return }
        AudioActivity.shared.suppressCamera = true
        let s = session
        queue.async { s.startRunning() }
        state = .running
    }

    private func configure() -> Bool {
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            state = .unavailable
            return false
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        configured = true
        return true
    }
}

/// AVCaptureVideoPreviewLayer-backed view; mirroring is applied in SwiftUI so it's deterministic.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            preview.videoGravity = .resizeAspectFill
            layer = preview          // layer-hosting: assign the layer first…
            wantsLayer = true        // …then opt in
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            if let c = preview.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false
            }
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        return v
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.preview.session !== session { nsView.preview.session = session }
        nsView.needsLayout = true
    }
}
