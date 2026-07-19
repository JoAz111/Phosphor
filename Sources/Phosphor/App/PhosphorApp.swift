import AppKit
import SwiftUI

@main
struct PhosphorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var playerStore = PlayerStore()

    var body: some Scene {
        WindowGroup("Phosphor") {
            ContentView(store: playerStore)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 960, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    playerStore.presentOpenPanel()
                }
                .keyboardShortcut("o")
            }

            CommandGroup(after: .toolbar) {
                Button(playerStore.transport == .playing ? "Pause" : "Play") {
                    playerStore.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playerStore.hasMedia)
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
