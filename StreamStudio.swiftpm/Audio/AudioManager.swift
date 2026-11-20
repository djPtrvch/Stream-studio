import AVFoundation
import Accelerate

/// Microphone selection by explicit choice (not "last plugged in") + level meters.
final class AudioManager: ObservableObject {
    struct Input: Identifiable, Hashable {
        let id: String      // AVAudioSessionPortDescription.uid
        let name: String
        let kind: String
        let channels: Int
    }

    @Published private(set) var inputs: [Input] = []
    @Published private(set) var currentID: String?
    @Published private(set) var preferredID: String?
    /// Peak level per channel, 0...1, with decay.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var permissionDenied = false

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var tokens: [NSObjectProtocol] = []
    private var started = false
    private let log = EventLog.shared
    private let defaultsKey = "audio.preferredInputUID"

    init() {
        preferredID = UserDefaults.standard.string(forKey: defaultsKey)
    }

    var currentInput: Input? { inputs.first { $0.id == currentID } }

    // MARK: - Public

    func start() {
        guard !started else { return }
        started = true
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    self.configure()
                } else {
                    self.permissionDenied = true
                    self.log.add("Нет доступа к микрофону")
                }
            }
        }
    }

    func select(_ id: String) {
        preferredID = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        applyPreferred()
        restartEngine()
    }

    // MARK: - Setup

    private func configure() {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            log.add("Аудиосессия: \(error.localizedDescription)")
        }
        observeNotifications()
        refresh()
        applyPreferred()
        restartEngine()
    }

    private func refresh() {
        inputs = (session.availableInputs ?? []).map { port in
            Input(id: port.uid, name: port.portName, kind: Self.kind(of: port.portType), channels: port.channels?.count ?? 0)
        }
        currentID = session.currentRoute.inputs.first?.uid
    }

    /// Re-asserts the user's choice. iOS switches to newly plugged devices on its own;
    /// we switch back unless the user picks the new device explicitly.
    private func applyPreferred() {
        guard let preferredID,
              let port = session.availableInputs?.first(where: { $0.uid == preferredID }) else { return }
        do {
            if session.currentRoute.inputs.first?.uid != preferredID {
                try session.setPreferredInput(port)
                log.add("Микрофон: \(port.portName)")
            }
            let maxChannels = session.maximumInputNumberOfChannels
            if maxChannels > 1 {
                try session.setPreferredInputNumberOfChannels(maxChannels)
            }
        } catch {
            log.add("Не удалось выбрать микрофон: \(error.localizedDescription)")
        }
        refresh()
    }

    // MARK: - Engine / meters

    private func restartEngine() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            levels = []
            log.add("Нет активного аудиовхода")
            return
        }
        sampleRate = format.sampleRate
        levels = Array(repeating: 0, count: Int(format.channelCount))

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.add("Аудиодвижок: \(error.localizedDescription)")
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peaks = [Float](repeating: 0, count: channels)
        for c in 0..<channels {
            var peak: Float = 0
            vDSP_maxmgv(data[c], 1, &peak, frames)
            peaks[c] = min(peak, 1)
        }
        DispatchQueue.main.async {
            if self.levels.count != peaks.count {
                self.levels = peaks
            } else {
                self.levels = zip(self.levels, peaks).map { max($1, $0 * 0.85) }
            }
        }
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default

        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            self.refresh()
            switch reason {
            case .newDeviceAvailable:
                self.log.add("Подключено аудиоустройство. Текущий выбор сохранён.")
                self.applyPreferred()
                self.restartEngine()
            case .oldDeviceUnavailable:
                self.log.add("Аудиоустройство отключено. Сейчас: \(self.currentInput?.name ?? "—")")
                self.restartEngine()
            default:
                break
            }
        })

        tokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartEngine()
        })

        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue {
                try? self.session.setActive(true)
                self.restartEngine()
                self.log.add("Аудио возобновлено")
            } else {
                self.log.add("⚠️ Аудио прервано")
            }
        })
    }

    private static func kind(of type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: return "Встроенный"
        case .usbAudio: return "USB"
        case .headsetMic: return "Гарнитура"
        case .bluetoothHFP: return "Bluetooth"
        case .lineIn: return "Линейный"
        default: return type.rawValue
        }
    }
}
