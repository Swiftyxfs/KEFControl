import AppKit
import SwiftUI

@main
struct KEFControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            SpeakerMenuView()
                .environmentObject(appState)
        } label: {
            Image(systemName: statusItemImageName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var statusItemImageName: String {
        appState.isConnected && appState.status == .powerOn ? "hifispeaker.fill" : "hifispeaker"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
