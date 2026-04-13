import AVFoundation
import OSLog

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String

    /// Virtual entry representing the system default input
    static let systemDefault = AudioInputDevice(id: "", name: "System Default")
}

@Observable
@MainActor
final class AudioDeviceMonitor {
    private(set) var devices: [AudioInputDevice] = [AudioInputDevice.systemDefault]

    private let settings: AppSettings
    private nonisolated(unsafe) var connectObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var disconnectObserver: (any NSObjectProtocol)?

    init(settings: AppSettings, skipHardware: Bool = false) {
        self.settings = settings
        guard !skipHardware else { return }
        refreshDevices()
        startObserving()
    }

    /// The currently selected device ID (empty string = system default)
    var selectedDeviceID: String {
        get { settings.audioSettings.preferredInputDeviceID ?? "" }
        set { settings.audioSettings.preferredInputDeviceID = newValue.isEmpty ? nil : newValue }
    }

    /// The device UID to pass to audio APIs, or nil for system default
    var selectedDeviceUID: String? {
        let id = selectedDeviceID
        return id.isEmpty ? nil : id
    }

    // MARK: - Device Enumeration

    private func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let inputDevices = discoverySession.devices.map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
        devices = [AudioInputDevice.systemDefault] + inputDevices
        Logger.audio.info("Found \(inputDevices.count) input device(s)")

        // Fall back to system default if selected device was disconnected
        if !selectedDeviceID.isEmpty,
           !devices.contains(where: { $0.id == selectedDeviceID }) {
            Logger.audio.info("Selected device disconnected, falling back to system default")
            selectedDeviceID = ""
        }
    }

    // MARK: - Observation

    private func startObserving() {
        let center = NotificationCenter.default
        connectObserver = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDevices()
            }
        }
        disconnectObserver = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDevices()
            }
        }
    }

    deinit {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }
}
