import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var cameras: CameraManager
    @EnvironmentObject private var audio: AudioManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("layout.mode") private var modeRaw = LayoutMode.pip.rawValue
    @AppStorage("layout.primary") private var primaryRaw = Slot.a.rawValue
    @State private var showDiagnostics = false

    private var mode: LayoutMode { LayoutMode(rawValue: modeRaw) ?? .pip }
    private var primary: Slot { Slot(rawValue: primaryRaw) ?? .a }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            CanvasView(mode: mode, primary: primary)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            layoutBar
            bottomBar
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .onChange(of: scenePhase) { _, phase in
            let name: String
            switch phase {
            case .active: name = "на экране"
            case .inactive: name = "неактивно"
            case .background: name = "в фоне"
            @unknown default: name = "?"
            }
            EventLog.shared.add("Приложение: \(name)")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("Stream Studio").font(.headline)
            Spacer()
            StatusDot(on: cameras.isRunning, label: cameras.isRunning ? "Камеры работают" : "Камеры остановлены")
            Button {
                showDiagnostics = true
            } label: {
                Label("Диагностика", systemImage: "stethoscope")
            }
            .keyboardShortcut("d", modifiers: .command)
        }
    }

    // MARK: - Layout buttons

    private var layoutBar: some View {
        HStack(spacing: 8) {
            layoutButton("A", key: "1", mode: .single, primary: .a)
            layoutButton("B", key: "2", mode: .single, primary: .b)
            layoutButton("A + b", key: "3", mode: .pip, primary: .a)
            layoutButton("B + a", key: "4", mode: .pip, primary: .b)
            layoutButton("A | B", key: "5", mode: .side, primary: primary)
            Button {
                withAnimation { primaryRaw = (primary == .a ? Slot.b : Slot.a).rawValue }
            } label: {
                LayoutChip(title: "⇄", hint: "⌘S", selected: false)
            }
            .keyboardShortcut("s", modifiers: .command)
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private func layoutButton(_ title: String, key: Character, mode: LayoutMode, primary: Slot) -> some View {
        let selected = self.mode == mode && (mode == .side || self.primary == primary)
        return Button {
            withAnimation {
                modeRaw = mode.rawValue
                primaryRaw = primary.rawValue
            }
        } label: {
            LayoutChip(title: title, hint: "⌘\(key)", selected: selected)
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            ForEach(Slot.allCases) { slot in
                CameraPicker(slot: slot)
            }
            Spacer()
            MicPicker()
            LevelMeters(levels: audio.levels)
                .frame(width: 120, height: 28)
        }
    }
}

// MARK: - Canvas

struct CanvasView: View {
    @EnvironmentObject private var cameras: CameraManager
    let mode: LayoutMode
    let primary: Slot

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Slot.allCases) { slot in
                    let p = LayoutEngine.placement(for: slot, primary: primary, mode: mode, in: geo.size)
                    SlotView(slot: slot)
                        .frame(width: p.rect.width, height: p.rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: p.cornerRadius)
                                .stroke(Color.white.opacity(p.cornerRadius > 0 ? 0.6 : 0), lineWidth: 2)
                        )
                        .position(x: p.rect.midX, y: p.rect.midY)
                        .opacity(p.visible ? 1 : 0)
                        .zIndex(p.zIndex)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.3), value: mode)
        .animation(.easeInOut(duration: 0.3), value: primary)
    }
}

struct SlotView: View {
    @EnvironmentObject private var cameras: CameraManager
    let slot: Slot

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layer = cameras.previewLayers[slot] {
                CameraPreviewView(layer: layer)
            }
            if cameras.active[slot] == nil {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                    Text(cameras.slotError[slot] ?? "Камера \(slot.rawValue) не выбрана")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
            }
            Text(slot.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(8)
        }
    }
}

// MARK: - Controls

struct CameraPicker: View {
    @EnvironmentObject private var cameras: CameraManager
    let slot: Slot

    var body: some View {
        Menu {
            Button("Нет") { cameras.assign(slot, to: nil) }
            ForEach(cameras.cameras) { camera in
                Button {
                    cameras.assign(slot, to: camera.id)
                } label: {
                    if cameras.wanted[slot] == camera.id {
                        Label(camera.title, systemImage: "checkmark")
                    } else {
                        Text(camera.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "video")
                Text("\(slot.rawValue):")
                    .bold()
                Text(cameras.camera(id: cameras.wanted[slot])?.name ?? "—")
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.15), in: Capsule())
        }
    }
}

struct MicPicker: View {
    @EnvironmentObject private var audio: AudioManager

    var body: some View {
        Menu {
            ForEach(audio.inputs) { input in
                Button {
                    audio.select(input.id)
                } label: {
                    let title = input.channels > 0 ? "\(input.name) · \(input.kind) · \(input.channels) кан." : "\(input.name) · \(input.kind)"
                    if audio.currentID == input.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                Text(audio.currentInput?.name ?? (audio.permissionDenied ? "Нет доступа" : "—"))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.15), in: Capsule())
        }
    }
}

struct LevelMeters: View {
    let levels: [Float]

    var body: some View {
        let shown = Array(levels.prefix(8))
        VStack(spacing: 2) {
            ForEach(shown.indices, id: \.self) { i in
                GeometryReader { geo in
                    let value = CGFloat(Self.meterValue(shown[i]))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.2))
                        Capsule()
                            .fill(shown[i] > 0.89 ? Color.red : (shown[i] > 0.5 ? Color.yellow : Color.green))
                            .frame(width: geo.size.width * value)
                    }
                }
            }
        }
    }

    /// Maps linear peak to a -60…0 dB scale.
    static func meterValue(_ linear: Float) -> Float {
        guard linear > 0 else { return 0 }
        let db = 20 * log10(linear)
        return max(0, min(1, (db + 60) / 60))
    }
}

struct LayoutChip: View {
    let title: String
    let hint: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.callout.bold())
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.35) : Color(white: 0.15),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusDot: View {
    let on: Bool
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
