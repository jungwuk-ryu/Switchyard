import AppKit
import Foundation

enum RosettaInstallerError: LocalizedError {
    case cancelledOrFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelledOrFailed(let detail):
            detail.isEmpty
                ? "Rosetta 2 was not installed. Try again, or ask your Mac administrator if this Mac is managed."
                : "Rosetta 2 was not installed: \(detail)"
        }
    }
}

@MainActor
struct RosettaInstaller {
    private static let updaterURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/Rosetta 2 Updater.app",
        isDirectory: true
    )
    private static let installationMarkers = [
        "/Library/Apple/usr/share/rosetta/rosetta",
        "/Library/Apple/usr/libexec/oah/runtime"
    ]

    func install() async throws {
        if Self.isInstalled {
            return
        }

        if FileManager.default.fileExists(atPath: Self.updaterURL.path) {
            try await installUsingAppleUpdater()
        } else {
            try await installUsingSoftwareUpdate()
        }

        guard Self.isInstalled else {
            throw RosettaInstallerError.cancelledOrFailed("")
        }
    }

    private func installUsingAppleUpdater() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.openApplication(
                at: Self.updaterURL,
                configuration: configuration
            ) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: error ?? RosettaInstallerError.cancelledOrFailed("")
                    )
                }
            }
        }

        for _ in 0..<1_200 {
            if Self.isInstalled {
                return
            }
            if application.isTerminated {
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func installUsingSoftwareUpdate() async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            process.arguments = ["--install-rosetta", "--agree-to-license"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output

            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationReason, process.terminationStatus, data)
        }.value

        guard result.0 == .exit, result.1 == 0 else {
            let detail = String(data: result.2, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RosettaInstallerError.cancelledOrFailed(detail)
        }
    }

    private static var isInstalled: Bool {
        installationMarkers.contains(where: FileManager.default.fileExists(atPath:))
    }
}
