import AppCore
import Foundation

enum ContainerPathPresentation {
    static func windowsPath(for filePath: String, in container: Container) -> String {
        let rootURL = URL(fileURLWithPath: container.path, isDirectory: true).standardizedFileURL
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        let driveCURL = rootURL.appendingPathComponent("drive_c", isDirectory: true)
        let driveCPath = driveCURL.path

        guard fileURL.path.hasPrefix(driveCPath + "/") else {
            return relativePath(for: filePath, in: container)
        }

        let relative = String(fileURL.path.dropFirst(driveCPath.count + 1))
        return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    static func relativePath(for filePath: String, in container: Container) -> String {
        let rootPath = URL(fileURLWithPath: container.path, isDirectory: true).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return filePath }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
