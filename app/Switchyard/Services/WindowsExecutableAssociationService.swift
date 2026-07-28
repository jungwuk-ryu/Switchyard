import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class WindowsExecutableAssociationService: ObservableObject {
    enum State: Equatable {
        case checking
        case available
        case defaultApplication
        case failed(String)

        var isWorking: Bool {
            self == .checking
        }

        var isDefaultApplication: Bool {
            self == .defaultApplication
        }

        var errorMessage: String? {
            guard case .failed(let message) = self else { return nil }
            return message
        }
    }

    @Published private(set) var state: State = .checking

    private let applicationURL: URL
    private let workspace: NSWorkspace

    init(
        applicationURL: URL = Bundle.main.bundleURL,
        workspace: NSWorkspace = .shared
    ) {
        self.applicationURL = applicationURL
        self.workspace = workspace
    }

    func refresh() {
        guard let executableType = UTType(filenameExtension: "exe") else {
            state = .available
            return
        }
        state = Self.refersToSameApplication(
            workspace.urlForApplication(toOpen: executableType),
            applicationURL
        ) ? .defaultApplication : .available
    }

    func makeDefaultApplication() {
        guard !state.isWorking,
              let executableType = UTType(filenameExtension: "exe") else {
            return
        }

        state = .checking
        workspace.setDefaultApplication(
            at: applicationURL,
            toOpen: executableType
        ) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                } else {
                    self.refresh()
                }
            }
        }
    }

    nonisolated static func refersToSameApplication(
        _ lhs: URL?,
        _ rhs: URL
    ) -> Bool {
        guard let lhs else { return false }
        return normalizedApplicationURL(lhs) == normalizedApplicationURL(rhs)
    }

    nonisolated private static func normalizedApplicationURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
