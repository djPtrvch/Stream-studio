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

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        if Thread.isMainThread {
            append(line)
        } else {
            DispatchQueue.main.async { self.append(line) }
        }
    }

    private func append(_ line: String) {
        entries.append(line)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
}
