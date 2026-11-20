import Foundation

/// Simple in-app log used by the diagnostics screen.
final class EventLog: ObservableObject {
    static let shared = EventLog()

    @Published private(set) var entries: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var lastMessage = ""
    private var repeatCount = 1

    func add(_ message: String) {
        let time = formatter.string(from: Date())
        if Thread.isMainThread {
            append(message, time: time)
        } else {
            DispatchQueue.main.async { self.append(message, time: time) }
        }
    }

    /// Collapses repeated messages into "message ×N".
    private func append(_ message: String, time: String) {
        if message == lastMessage, !entries.isEmpty {
            repeatCount += 1
            entries[entries.count - 1] = "\(time) \(message) ×\(repeatCount)"
            return
        }
        lastMessage = message
        repeatCount = 1
        entries.append("\(time) \(message)")
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
}
