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
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var menuBarIcon: String {
        if appState.isConnected && appState.status == .powerOn {
            "hifispeaker.fill"
        } else {
            "hifispeaker"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — this is a menu bar-only app
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
