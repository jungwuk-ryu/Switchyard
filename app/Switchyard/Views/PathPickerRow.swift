import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PathPickerSelectionKind: Equatable, Sendable {
    case directory
    case windowsExecutable
    case gamePortingToolkit
    case wineRuntime

    var canChooseDirectories: Bool {
        switch self {
        case .directory, .gamePortingToolkit, .wineRuntime:
            true
        case .windowsExecutable:
            false
        }
    }

    var canChooseFiles: Bool {
        self != .directory
    }

    var allowedContentTypes: [UTType] {
        switch self {
        case .directory:
            [.folder]
        case .windowsExecutable:
            Self.contentTypes(forExtensions: ["exe", "msi"])
        case .gamePortingToolkit:
            [.folder] + Self.contentTypes(forExtensions: ["dmg"])
        case .wineRuntime:
            [.folder, .unixExecutable]
        }
    }

    func acceptedPath(
        for selectedURL: URL?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let selectedURL,
              selectedURL.isFileURL,
              selectedURL.baseURL == nil else {
            return nil
        }

        let selectedPath = selectedURL.path
        guard selectedPath.hasPrefix("/"),
              selectedPath != "/",
              !selectedPath.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              }) else {
            return nil
        }

        guard !selectedURL.pathComponents.dropFirst().contains(where: {
                  $0 == "." || $0 == ".."
              }),
              !containsSymbolicLink(
                  in: selectedURL,
                  fileManager: fileManager
              ),
              let values = try? selectedURL.resourceValues(
                  forKeys: [
                      .isDirectoryKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                  ]
              ),
              values.isSymbolicLink != true else {
            return nil
        }

        switch self {
        case .directory:
            guard values.isDirectory == true else { return nil }
        case .windowsExecutable:
            guard values.isRegularFile == true,
                  ["exe", "msi"].contains(
                      selectedURL.pathExtension.lowercased()
                  ) else {
                return nil
            }
        case .gamePortingToolkit:
            guard values.isDirectory == true
                    || (
                        values.isRegularFile == true
                            && selectedURL.pathExtension
                                .caseInsensitiveCompare("dmg") == .orderedSame
                    ) else {
                return nil
            }
        case .wineRuntime:
            guard values.isDirectory == true
                    || (
                        values.isRegularFile == true
                            && fileManager.isExecutableFile(
                                atPath: selectedURL.path
                            )
                    ) else {
                return nil
            }
        }

        return selectedPath
    }

    private static func contentTypes(
        forExtensions extensions: [String]
    ) -> [UTType] {
        extensions.compactMap {
            UTType(filenameExtension: $0)
        }
    }

    private func containsSymbolicLink(
        in url: URL,
        fileManager: FileManager
    ) -> Bool {
        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            currentURL.appendPathComponent(component)
            guard fileManager.fileExists(atPath: currentURL.path),
                  let values = try? currentURL.resourceValues(
                      forKeys: [.isSymbolicLinkKey]
                  ) else {
                return true
            }
            if values.isSymbolicLink == true {
                return true
            }
        }
        return false
    }
}

struct PathPickerRow: View {
    let title: String
    let message: String
    let selectionKind: PathPickerSelectionKind
    var initialDirectoryURL: URL?
    @Binding var path: String
    var onChange: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 150, alignment: .leading)

            Text(
                path.isEmpty
                    ? String(localized: "Not selected", bundle: SwitchyardStrings.bundle)
                    : path
            )
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)

            Spacer(minLength: 12)

            Button("Choose...") {
                choosePath()
            }
        }
        .help(message)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = selectionKind.canChooseDirectories
        panel.canChooseFiles = selectionKind.canChooseFiles
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = selectionKind.allowedContentTypes
        panel.resolvesAliases = false
        panel.directoryURL = initialDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let isAccessingSecurityScopedResource =
            url.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let acceptedPath = selectionKind.acceptedPath(for: url) else {
            NSSound.beep()
            return
        }
        path = acceptedPath
        onChange()
    }
}
