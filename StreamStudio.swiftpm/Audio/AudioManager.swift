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
    @Published private(set) var outputName: String = "—"
    /// Peak level per channel, 0...1, with decay.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var permissionDenied = false
    @Published private(set) var switching = false

    private let session = AVAudioSession.sharedInstance()
    /// Recreated on every restart: a stale engine keeps the old hardware format (error -10868).
    private var engine = AVAudioEngine()
    private var engineRunning = false
    private var tokens: [NSObjectProtocol] = []
    private var started = false
    private var restartWork: DispatchWorkItem?
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

    /// Switch order matters: stop engine → deactivate → prefer → activate → new engine.
    func select(_ id: String) {
        preferredID = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else {
            log.add("Микрофон недоступен")
            return
        }
        log.add("Выбор микрофона: \(port.portName)")
        switching = true
        stopEngine()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.add("Деактивация: \(Self.describe(error))")
        }
        do {
            try session.setPreferredInput(port)
            try session.setActive(true)
        } catch {
            log.add("Не удалось выбрать: \(Self.describe(error))")
        }
        maximizeChannels()
        // Give iOS a moment to rebuild the route, then verify.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.refresh()
            self.logRoute("после выбора")
            if self.currentID != id {
                self.log.add("⚠️ iOS не переключил вход (предпочтение: \(self.session.preferredInput?.portName ?? "нет"))")
            }
            self.switching = false
            self.startEngine()
        }
    }

    // MARK: - Setup

    private func configure() {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            log.add("Аудиосессия: \(Self.describe(error))")
        }
        observeNotifications()
        refresh()
        logRoute("старт")
        if let preferredID, currentID != preferredID,
           session.availableInputs?.contains(where: { $0.uid == preferredID }) == true {
            select(preferredID)
        } else {
            maximizeChannels()
            startEngine()
        }
    }

    private func refresh() {
        inputs = (session.availableInputs ?? []).map { port in
            Input(id: port.uid, name: port.portName, kind: Self.kind(of: port.portType), channels: port.channels?.count ?? 0)
        }
        currentID = session.currentRoute.inputs.first?.uid
        outputName = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
    }

    private func maximizeChannels() {
        let maxChannels = session.maximumInputNumberOfChannels
        guard maxChannels > 1 else { return }
        do {
            try session.setPreferredInputNumberOfChannels(maxChannels)
        } catch {
            log.add("Каналы: \(Self.describe(error))")
        }
    }

    private func logRoute(_ context: String) {
        let input = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        let output = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        log.add("Маршрут (\(context)): вход=\(input.isEmpty ? "—" : input) выход=\(output.isEmpty ? "—" : output) каналов=\(session.inputNumberOfChannels)")
    }

    // MARK: - Engine / meters

    private func stopEngine() {
        restartWork?.cancel()
        if engineRunning || engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engineRunning = false
    }

    /// Debounced: route/config notifications often arrive in bursts.
    private func scheduleRestart() {
        guard !switching else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startEngine() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func startEngine() {
        stopEngine()
        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            levels = []
            log.add("Нет активного аудиовхода")
            return
        }
        sampleRate = format.sampleRate
        levels = Array(repeating: 0, count: Int(format.channelCount))

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            engineRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            log.add("Аудиодвижок: \(Self.describe(error))")
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
            guard !self.switching else { return }
            switch reason {
            case .newDeviceAvailable:
                self.logRoute("подключено устройство")
                // iOS jumps to the new device by itself. Return to the user's choice.
                if let preferredID = self.preferredID, self.currentID != preferredID,
                   self.session.availableInputs?.contains(where: { $0.uid == preferredID }) == true {
                    self.log.add("Возвращаю выбранный микрофон")
                    self.select(preferredID)
                } else {
                    self.scheduleRestart()
                }
            case .oldDeviceUnavailable:
                self.logRoute("устройство отключено")
                self.scheduleRestart()
            case .some(let r):
                self.logRoute("причина \(Self.describe(r))")
            case .none:
                break
            }
        })

        tokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as AnyObject? === self.engine else { return }
            self.log.add("Аудио: смена конфигурации устройства")
            self.scheduleRestart()
        })

        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .ended {
                self.log.add("Аудио возобновлено")
                try? self.session.setActive(true)
                self.scheduleRestart()
            } else {
                var details: [String] = []
                if let r = info[AVAudioSessionInterruptionReasonKey] as? UInt {
                    details.append("причина \(r)")
                }
                if let suspended = info[AVAudioSessionInterruptionWasSuspendedKey] as? Bool, suspended {
                    details.append("приложение было приостановлено")
                }
                if self.session.isOtherAudioPlaying { details.append("играет другое аудио") }
                self.log.add("⚠️ Аудио прервано \(details.joined(separator: ", "))")
            }
        })

        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log.add("⚠️ Аудиосистема перезапущена")
            self.configure()
        })
    }

    // MARK: - Helpers

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

    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .categoryChange: return "смена категории"
        case .override: return "переопределение"
        case .wakeFromSleep: return "выход из сна"
        case .noSuitableRouteForCategory: return "нет подходящего маршрута"
        case .routeConfigurationChange: return "смена конфигурации"
        default: return "код \(reason.rawValue)"
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
