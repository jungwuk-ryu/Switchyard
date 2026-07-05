import AppKit
import SwiftUI

@main
struct SwitchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("Containers", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    store.refreshRuntimeStatus()
                }
        }
        .commands {
            CommandMenu("Switchyard") {
                Button("Add Container") {
                    store.addContainer()
                }
                .keyboardShortcut("n")

                Button("Run Container") {
                    store.runSelectedContainer()
                }
                .keyboardShortcut("r")

                Button("Stop Operation") {
                    store.stopRunningOperations()
                }
                .keyboardShortcut(".")

                Button("Open Logs") {
                    store.selectedSection = .logs
                }
                .keyboardShortcut("l")

                Button("Diagnostics") {
                    store.selectedSection = .diagnostics
                }
                .keyboardShortcut("d")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
