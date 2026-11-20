import AVFoundation
import UIKit

enum Slot: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    var id: String { rawValue }
}

struct CameraInfo: Identifiable, Hashable {
    enum Kind: String {
        case front = "Фронтальная"
        case back = "Задняя"
        case external = "USB"
    }

    let id: String          // AVCaptureDevice.uniqueID
    let name: String
    let kind: Kind
    let formatCount: Int
    let multiCamFormatCount: Int
    let maxResolution: String

    var title: String { "\(name) · \(kind.rawValue)" }
}

/// Owns the capture session and routes up to two cameras to slot A / slot B previews.
final class CameraManager: ObservableObject {
    @Published private(set) var cameras: [CameraInfo] = []
    /// Cameras the user picked (persisted). Kept even when a device is unplugged.
    @Published private(set) var wanted: [Slot: String] = [:]
    /// Cameras actually running right now.
    @Published private(set) var active: [Slot: String] = [:]
    @Published private(set) var slotError: [Slot: String] = [:]
    @Published private(set) var multiCamSets: [[String]] = []
    @Published private(set) var multitaskingSupported = false
    @Published private(set) var multitaskingEnabled = false
    @Published private(set) var hardwareCost: Float = 0
    @Published private(set) var pressureCost: Float = 0
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    let isMultiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
    let session: AVCaptureSession
    let previewLayers: [Slot: AVCaptureVideoPreviewLayer]

    private let queue = DispatchQueue(label: "streamstudio.camera.session")
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .external],
        mediaType: .video,
        position: .unspecified
    )
    private var inputs: [String: AVCaptureDeviceInput] = [:]
    private var rotationCoordinators: [Slot: AVCaptureDevice.RotationCoordinator] = [:]
    private var rotationObservers: [Slot: NSKeyValueObservation] = [:]
    private var devicesObserver: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var started = false
    private let log = EventLog.shared

    init() {
        session = AVCaptureMultiCamSession.isMultiCamSupported ? AVCaptureMultiCamSession() : AVCaptureSession()
        var layers: [Slot: AVCaptureVideoPreviewLayer] = [:]
        for slot in Slot.allCases {
            let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            layer.videoGravity = .resizeAspectFill
            layers[slot] = layer
        }
        previewLayers = layers

        for slot in Slot.allCases {
            if let id = UserDefaults.standard.string(forKey: "camera.slot.\(slot.rawValue)") {
                wanted[slot] = id
            }
        }
        observeNotifications()
    }

    // MARK: - Public

    func start() {
        guard !started else { return }
        started = true
        log.add("Мультикамера поддерживается: \(isMultiCamSupported ? "да" : "нет")")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.permissionDenied = true
                    self.log.add("Нет доступа к камере")
                    return
                }
                self.refreshDevices()
                if self.wanted.isEmpty { self.assignDefaults() }
                self.applyConfiguration()
            }
        }
    }

    func assign(_ slot: Slot, to deviceID: String?) {
        wanted[slot] = deviceID
        UserDefaults.standard.set(deviceID, forKey: "camera.slot.\(slot.rawValue)")
        applyConfiguration()
    }

    func camera(id: String?) -> CameraInfo? {
        guard let id else { return nil }
        return cameras.first { $0.id == id }
    }

    // MARK: - Devices

    private func assignDefaults() {
        if let back = cameras.first(where: { $0.kind == .back }) { wanted[.a] = back.id }
        if isMultiCamSupported, let front = cameras.first(where: { $0.kind == .front }) { wanted[.b] = front.id }
        for slot in Slot.allCases {
            UserDefaults.standard.set(wanted[slot], forKey: "camera.slot.\(slot.rawValue)")
        }
    }

    private func refreshDevices() {
        cameras = discovery.devices.map(Self.info(for:))
        multiCamSets = discovery.supportedMultiCamDeviceSets.map { set in
            set.map(\.localizedName).sorted()
        }
    }

    private static func info(for device: AVCaptureDevice) -> CameraInfo {
        let kind: CameraInfo.Kind
        if device.deviceType == .external {
            kind = .external
        } else if device.position == .front {
            kind = .front
        } else {
            kind = .back
        }
        var best: (Int32, Int32) = (0, 0)
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if d.width * d.height > best.0 * best.1 { best = (d.width, d.height) }
        }
        return CameraInfo(
            id: device.uniqueID,
            name: device.localizedName,
            kind: kind,
            formatCount: device.formats.count,
            multiCamFormatCount: device.formats.filter(\.isMultiCamSupported).count,
            maxResolution: "\(best.0)×\(best.1)"
        )
    }

    // MARK: - Session configuration

    private func applyConfiguration() {
        let wantedSnapshot = wanted
        let multiCamSupported = isMultiCamSupported

        queue.async { [self] in
            session.beginConfiguration()

            if session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true
            }
            for connection in session.connections { session.removeConnection(connection) }
            for input in session.inputs { session.removeInput(input) }
            inputs.removeAll()

            var newActive: [Slot: String] = [:]
            var errors: [Slot: String] = [:]
            let distinct = Set(wantedSnapshot.values)
            let needsMultiCam = distinct.count > 1

            for slot in Slot.allCases {
                guard let id = wantedSnapshot[slot] else { continue }
                if slot == .b && !multiCamSupported && id != wantedSnapshot[.a] {
                    errors[slot] = "Мультикамера не поддерживается"
                    continue
                }
                guard let device = AVCaptureDevice(uniqueID: id) else {
                    errors[slot] = "Камера отключена"
                    continue
                }
                do {
                    let input: AVCaptureDeviceInput
                    if let existing = inputs[id] {
                        input = existing
                    } else {
                        input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else {
                            errors[slot] = "Нельзя добавить камеру в сессию"
                            continue
                        }
                        session.addInputWithNoConnections(input)
                        inputs[id] = input
                        if needsMultiCam && multiCamSupported {
                            selectMultiCamFormat(for: device)
                        }
                    }
                    guard let port = input.ports.first(where: { $0.mediaType == .video }),
                          let layer = previewLayers[slot] else {
                        errors[slot] = "Нет видеопорта"
                        continue
                    }
                    let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
                    guard session.canAddConnection(connection) else {
                        errors[slot] = "Нельзя подключить превью (сочетание камер не поддерживается?)"
                        continue
                    }
                    session.addConnection(connection)
                    newActive[slot] = id
                } catch {
                    errors[slot] = error.localizedDescription
                }
            }

            session.commitConfiguration()

            var hw: Float = 0
            var pressure: Float = 0
            if let multi = session as? AVCaptureMultiCamSession {
                hw = multi.hardwareCost
                pressure = multi.systemPressureCost
                if hw > 1 {
                    for slot in newActive.keys { errors[slot] = "Превышен лимит мультикамеры (\(String(format: "%.2f", hw)))" }
                }
            }

            if !session.isRunning && !session.inputs.isEmpty {
                session.startRunning()
            }

            let running = session.isRunning
            let mtSupported = session.isMultitaskingCameraAccessSupported
            let mtEnabled = session.isMultitaskingCameraAccessEnabled

            DispatchQueue.main.async {
                self.active = newActive
                self.slotError = errors
                self.hardwareCost = hw
                self.pressureCost = pressure
                self.isRunning = running
                self.multitaskingSupported = mtSupported
                self.multitaskingEnabled = mtEnabled
                self.setupRotation(for: newActive)
                let names = newActive.map { "\($0.key.rawValue)=\(self.camera(id: $0.value)?.name ?? "?")" }.sorted()
                self.log.add("Конфигурация: \(names.joined(separator: ", ")) · cost \(String(format: "%.2f", hw))")
                for (slot, error) in errors { self.log.add("Слот \(slot.rawValue): \(error)") }
            }
        }
    }

    /// Multi-cam sessions need formats flagged `isMultiCamSupported`. Prefer 1080p.
    private func selectMultiCamFormat(for device: AVCaptureDevice) {
        let candidates = device.formats.filter(\.isMultiCamSupported)
        guard !candidates.isEmpty else {
            log.add("\(device.localizedName): нет форматов для мультикамеры")
            return
        }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        let chosen = candidates.first { dims($0).width == 1920 && dims($0).height == 1080 && maxFPS($0) >= 30 }
            ?? candidates.filter { dims($0).width <= 1920 }.max { dims($0).width < dims($1).width }
            ?? candidates[0]
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            device.unlockForConfiguration()
            let d = dims(chosen)
            log.add("\(device.localizedName): формат \(d.width)×\(d.height)")
        } catch {
            log.add("\(device.localizedName): не удалось выбрать формат — \(error.localizedDescription)")
        }
    }

    // MARK: - Rotation

    private func setupRotation(for active: [Slot: String]) {
        rotationObservers.removeAll()
        rotationCoordinators.removeAll()
        for (slot, id) in active {
            guard let device = AVCaptureDevice(uniqueID: id), let layer = previewLayers[slot] else { continue }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
            rotationCoordinators[slot] = coordinator
            Self.apply(angle: coordinator.videoRotationAngleForHorizonLevelPreview, to: layer)
            rotationObservers[slot] = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak layer] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    guard let layer else { return }
                    Self.apply(angle: angle, to: layer)
                }
            }
        }
    }

    private static func apply(angle: CGFloat, to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default

        devicesObserver = discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }

        tokens.append(center.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let name = (note.object as? AVCaptureDevice)?.localizedName ?? "?"
            self.log.add("Камера подключена: \(name)")
            self.refreshDevices()
            // Restore a slot whose chosen camera came back.
            if let device = note.object as? AVCaptureDevice, self.wanted.values.contains(device.uniqueID) {
                self.applyConfiguration()
            }
        })

        tokens.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let name = (note.object as? AVCaptureDevice)?.localizedName ?? "?"
            self.log.add("Камера отключена: \(name)")
            self.refreshDevices()
            if let device = note.object as? AVCaptureDevice, self.active.values.contains(device.uniqueID) {
                self.applyConfiguration()
            }
        })

        tokens.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] note in
            var reason = "неизвестно"
            if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
               let value = AVCaptureSession.InterruptionReason(rawValue: raw) {
                reason = Self.describe(value)
            }
            self?.isRunning = false
            self?.log.add("⚠️ Камеры прерваны: \(reason)")
        })

        tokens.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            self?.isRunning = true
            self?.log.add("✅ Камеры возобновлены")
        })

        tokens.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.log.add("❌ Ошибка сессии: \(error?.localizedDescription ?? "?")")
        })
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "приложение в фоне"
        case .audioDeviceInUseByAnotherClient: return "аудио занято другим приложением"
        case .videoDeviceInUseByAnotherClient: return "камера занята другим приложением"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "несколько приложений на экране"
        case .videoDeviceNotAvailableDueToSystemPressure: return "перегрев / нагрузка системы"
        @unknown default: return "код \(reason.rawValue)"
        }
    }
}
