import SwiftUI
import UIKit

/// Shows what the iPad reports about cameras, multicam, multitasking and audio.
/// "Копировать отчёт" puts everything on the clipboard to paste back into the chat.
struct DiagnosticsView: View {
    @EnvironmentObject private var cameras: CameraManager
    @EnvironmentObject private var audio: AudioManager
    @EnvironmentObject private var log: EventLog
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("Как проверить") {
                    Text("1. Выбери A = задняя, B = фронтальная — работают ли обе одновременно?")
                    Text("2. Подключи Sony и Pixel 7 (USB → «Веб-камера») — появились ли в списке? Поставь их в A/B.")
                    Text("3. Открой приложение в Stage Manager рядом с другим и переключись в другое окно — что в журнале?")
                    Text("4. Подключи аудиокарту и USB-микрофон, переключайся между ними.")
                    Text("5. Нажми «Копировать отчёт» и вставь в чат.")
                }
                .font(.callout)

                Section("Сессия камер") {
                    row("Мультикамера", cameras.isMultiCamSupported ? "поддерживается" : "нет")
                    row("Камеры в многозадачности", cameras.multitaskingSupported
                        ? (cameras.multitaskingEnabled ? "включено" : "поддерживается, выключено")
                        : "не поддерживается")
                    row("Hardware cost", String(format: "%.2f", cameras.hardwareCost))
                    row("System pressure cost", String(format: "%.2f", cameras.pressureCost))
                    row("Работает", cameras.isRunning ? "да" : "нет")
                }

                Section("Камеры (\(cameras.cameras.count))") {
                    ForEach(cameras.cameras) { camera in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.title).bold()
                            Text("Макс. \(camera.maxResolution) · форматов \(camera.formatCount) · для мультикамеры \(camera.multiCamFormatCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Сочетания для мультикамеры") {
                    if cameras.multiCamSets.isEmpty {
                        Text("нет").foregroundStyle(.secondary)
                    }
                    ForEach(cameras.multiCamSets.indices, id: \.self) { i in
                        Text(cameras.multiCamSets[i].joined(separator: " + "))
                    }
                }

                Section("Звук") {
                    row("Текущий вход", audio.currentInput.map { "\($0.name) (\($0.kind))" } ?? "—")
                    row("Частота", audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Гц" : "—")
                    row("Каналов", "\(audio.levels.count)")
                    ForEach(audio.inputs) { input in
                        Text("• \(input.name) · \(input.kind) · \(input.channels) кан.")
                            .font(.caption)
                    }
                }

                Section("Журнал") {
                    ForEach(Array(log.entries.enumerated().reversed()), id: \.offset) { item in
                        Text(item.element).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Диагностика")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "Скопировано" : "Копировать отчёт") {
                        UIPasteboard.general.string = report()
                        copied = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func report() -> String {
        var lines: [String] = []
        lines.append("== Stream Studio диагностика ==")
        lines.append("iPadOS \(UIDevice.current.systemVersion)")
        lines.append("Мультикамера: \(cameras.isMultiCamSupported)")
        lines.append("Многозадачность камер: supported=\(cameras.multitaskingSupported) enabled=\(cameras.multitaskingEnabled)")
        lines.append("Hardware cost: \(cameras.hardwareCost), pressure: \(cameras.pressureCost)")
        lines.append("-- Камеры")
        for c in cameras.cameras {
            lines.append("\(c.title) | max \(c.maxResolution) | formats \(c.formatCount) | multicam \(c.multiCamFormatCount)")
        }
        lines.append("-- Сочетания мультикамеры")
        for set in cameras.multiCamSets { lines.append(set.joined(separator: " + ")) }
        lines.append("-- Слоты")
        for slot in Slot.allCases {
            let name = cameras.camera(id: cameras.active[slot])?.name ?? "—"
            lines.append("\(slot.rawValue): \(name) \(cameras.slotError[slot] ?? "")")
        }
        lines.append("-- Звук")
        lines.append("Текущий: \(audio.currentInput?.name ?? "—"), \(Int(audio.sampleRate)) Гц, \(audio.levels.count) кан.")
        for i in audio.inputs { lines.append("\(i.name) | \(i.kind) | \(i.channels) кан.") }
        lines.append("-- Журнал")
        lines.append(contentsOf: log.entries.suffix(150))
        return lines.joined(separator: "\n")
    }
}
