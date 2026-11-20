import SwiftUI

@main
struct StreamStudioApp: App {
    @StateObject private var cameras = CameraManager()
    @StateObject private var audio = AudioManager()
    @StateObject private var log = EventLog.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cameras)
                .environmentObject(audio)
                .environmentObject(log)
                .preferredColorScheme(.dark)
                .task {
                    cameras.start()
                    audio.start()
                }
        }
    }
}
