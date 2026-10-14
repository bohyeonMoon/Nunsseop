@preconcurrency import AVFoundation
import SwiftUI

/// Camera preview for the Mirror tab. The session only runs while the tab is visible.
@MainActor
final class MirrorModel: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = MirrorModel.currentAccess
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nunsseop.mirror")
    private var configuredDeviceID: String?

    private static var currentAccess: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    nonisolated static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    /// The name of the camera `deviceID` picks (empty means the system default), if there is one.
    nonisolated static func cameraName(for deviceID: String) -> String? {
        (cameras.first { $0.uniqueID == deviceID } ?? AVCaptureDevice.default(for: .video))?.localizedName
    }

    func requestAccess() {
        if access == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async { self?.access = granted ? .granted : .denied }
        }
    }

    /// `deviceID` empty means the system default camera.
    func start(deviceID: String) {
        access = Self.currentAccess
        guard access == .granted else { return }
        let session = session
        let needsConfigure = configuredDeviceID != deviceID
        configuredDeviceID = deviceID
        queue.async {
            if needsConfigure {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                let device = Self.cameras.first { $0.uniqueID == deviceID } ?? AVCaptureDevice.default(for: .video)
                if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

private final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        // Mirror the image like a real mirror.
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

struct MirrorTab: View {
    @ObservedObject var mirror: MirrorModel
    let deviceID: String
    @State private var cameraName: String?

    var body: some View {
        MirrorPanels(access: mirror.access, cameraName: cameraName, requestAccess: mirror.requestAccess) {
            CameraPreview(session: mirror.session)
                .onAppear { mirror.start(deviceID: deviceID) }
                .onDisappear { mirror.stop() }
                .onChange(of: deviceID) { _, id in mirror.start(deviceID: id) }
        }
        .task(id: deviceID) { cameraName = MirrorModel.cameraName(for: deviceID) }
    }
}

/// The preview (or the way to allow the camera) on the left, which camera it is and whether it is allowed on the right. The camera
/// is picked in Settings, so the rows only say what it is.
struct MirrorPanels<Preview: View>: View {
    let access: MirrorModel.Access
    let cameraName: String?
    let requestAccess: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if access == .granted {
                    preview.clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(Text("Camera preview"))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.5)).accessibilityHidden(true)
                        Text(access == .denied ? String(localized: "Camera access is off") : String(localized: "Use your camera as a mirror"))
                            .font(.system(size: 12)).foregroundStyle(PanelInk.hint)
                        PanelAction(title: access == .denied ? "Open System Settings" : "Allow Camera", style: .primary, action: requestAccess)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2), lineWidth: 0.75))
            .frame(width: 290)
            VStack(alignment: .leading, spacing: 0) {
                row(String(localized: "Camera"), cameraName ?? String(localized: "System default"))
                PanelHLine()
                row(String(localized: "Access"), accessText)
                HStack(spacing: 6) {
                    Image(systemName: "gearshape").font(.system(size: 10)).accessibilityHidden(true)
                    Text("Pick the camera in Settings › Services").font(.system(size: 11)).lineLimit(2)
                }
                .foregroundStyle(PanelInk.hint)
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
    }

    private var accessText: String {
        switch access {
        case .granted: return String(localized: "Allowed")
        case .denied: return String(localized: "Not allowed")
        case .unknown: return String(localized: "Not asked yet")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text.panel(label, size: 11, opacity: 0.6)
            Text.panel(value, size: 13, weight: .semibold).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
