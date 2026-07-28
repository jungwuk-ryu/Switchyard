import AppCore
import Foundation

enum WindowsExecutableProgramResolver {
    static func program(
        windowsPath: String,
        prefixPath: String,
        catalogPrograms: [InstalledProgram] = []
    ) -> InstalledProgram? {
        guard let normalizedPath = WineProtocolAssociationFormat
            .normalizedWindowsExecutablePath(windowsPath) else {
            return nil
        }

        if let catalogProgram = catalogPrograms.first(where: { program in
            guard let catalogWindowsPath = WineProtocolAssociationFormat
                .windowsExecutablePath(
                    hostPath: program.executablePath,
                    prefixPath: prefixPath
                ),
                  let normalizedCatalogPath = WineProtocolAssociationFormat
                    .normalizedWindowsExecutablePath(catalogWindowsPath) else {
                return false
            }
            return normalizedCatalogPath.caseInsensitiveCompare(normalizedPath)
                == .orderedSame
        }) {
            return catalogProgram
        }

        guard let executableURL = hostExecutableURL(
            windowsPath: normalizedPath,
            prefixPath: prefixPath
        ) else {
            return nil
        }
        let executableName = executableURL.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executableName.isEmpty else { return nil }

        return InstalledProgram(
            name: executableName,
            executablePath: executableURL.path,
            installDirectory: executableURL.deletingLastPathComponent().path,
            source: .programFiles
        )
    }

    static func hostExecutableURL(
        windowsPath: String,
        prefixPath: String
    ) -> URL? {
        guard let normalizedPath = WineProtocolAssociationFormat
            .normalizedWindowsExecutablePath(windowsPath) else {
            return nil
        }
        let drive = String(normalizedPath.prefix(1)).lowercased()
        let prefixURL = URL(
            fileURLWithPath: prefixPath,
            isDirectory: true
        ).standardizedFileURL
        let driveURL: URL
        if drive == "c" {
            driveURL = prefixURL.appendingPathComponent(
                "drive_c",
                isDirectory: true
            )
        } else {
            driveURL = prefixURL
                .appendingPathComponent("dosdevices", isDirectory: true)
                .appendingPathComponent("\(drive):", isDirectory: true)
        }

        let components = normalizedPath
            .dropFirst(3)
            .split(separator: "\\")
            .map(String.init)
        let executableURL = components.reduce(driveURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
        let resolvedDriveURL = driveURL.resolvingSymlinksInPath()
        let resolvedExecutableURL = executableURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(executableURL.lastPathComponent)
            .standardizedFileURL
        let rootPath = resolvedDriveURL.path
        let isContained = rootPath == "/"
            ? resolvedExecutableURL.path.hasPrefix("/")
            : resolvedExecutableURL.path.hasPrefix(rootPath + "/")
        guard isContained else { return nil }
        return executableURL
    }
}
