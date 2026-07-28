import AppKit
import SwiftUI

@main
struct SwitchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var updater = SwitchyardUpdater()

    var body: some Scene {
        WindowGroup("Containers", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.logStore)
                .environmentObject(updater)
                .handlesWindowsApplicationOpenEvents(
                    coordinator: appDelegate.windowsApplicationOpenCoordinator,
                    store: store
                )
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    store.refreshRuntimeStatus()
                    updater.start()
                }
        }
        .commands {
            CommandMenu("Switchyard") {
                Button("Add Container") {
                    store.addContainer()
                }
                .keyboardShortcut("n")
                .disabled(!store.hasCompletedSetup || !store.runtimeStatus.canLaunch)

                Button("Launch") {
                    store.runSelectedContainer()
                }
                .keyboardShortcut("r")
                .disabled(
                    !store.hasCompletedSetup
                        || !store.runtimeStatus.canLaunch
                        || (store.selectedContainer?.executablePath?.isEmpty ?? true)
                )

                Button("Stop All Windows Apps") {
                    store.stopAllRuns()
                }
                .keyboardShortcut(".")
                .disabled(!store.hasRunningContainers)

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
                .environmentObject(updater)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let windowsApplicationOpenCoordinator = WindowsApplicationOpenCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard windowsApplicationOpenCoordinator.enqueue(urls) else { return }
        windowsApplicationOpenCoordinator.showMainWindowIfNeeded()
        application.activate(ignoringOtherApps: true)
    }
}
