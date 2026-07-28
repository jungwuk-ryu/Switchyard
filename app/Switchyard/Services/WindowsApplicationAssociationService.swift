import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class WindowsApplicationAssociationService: ObservableObject {
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

    nonisolated static let supportedFilenameExtensions = ["exe", "msi"]

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
        let contentTypes = Self.supportedContentTypes
        guard contentTypes.count == Self.supportedFilenameExtensions.count else {
            state = .available
            return
        }

        let registeredApplications = contentTypes.map {
            workspace.urlForApplication(toOpen: $0)
        }
        state = Self.allReferToSameApplication(
            registeredApplications,
            applicationURL
        ) ? .defaultApplication : .available
    }

    func makeDefaultApplication() {
        let contentTypes = Self.supportedContentTypes
        guard !state.isWorking,
              contentTypes.count == Self.supportedFilenameExtensions.count else {
            return
        }

        state = .checking
        setDefaultApplication(for: contentTypes[...])
    }

    private func setDefaultApplication(for contentTypes: ArraySlice<UTType>) {
        guard let contentType = contentTypes.first else {
            refresh()
            return
        }

        workspace.setDefaultApplication(
            at: applicationURL,
            toOpen: contentType
        ) { [self] error in
            Task { @MainActor in
                if let error {
                    self.state = .failed(error.localizedDescription)
                } else {
                    self.setDefaultApplication(for: contentTypes.dropFirst())
                }
            }
        }
    }

    nonisolated static var supportedContentTypes: [UTType] {
        supportedFilenameExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .data)
        }
    }

    nonisolated static func allReferToSameApplication(
        _ registeredApplications: [URL?],
        _ applicationURL: URL
    ) -> Bool {
        !registeredApplications.isEmpty
            && registeredApplications.allSatisfy {
                refersToSameApplication($0, applicationURL)
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
