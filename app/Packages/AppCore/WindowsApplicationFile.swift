import Foundation

public enum WindowsApplicationFileKind: String, CaseIterable, Equatable, Sendable {
    case executable = "exe"
    case installerPackage = "msi"

    public init?(path: String) {
        self.init(rawValue: URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func supports(_ url: URL) -> Bool {
        Self(path: url.path) != nil
    }

    public func wineArguments(
        for applicationPath: String,
        additionalArguments: [String] = []
    ) -> [String] {
        switch self {
        case .executable:
            [applicationPath] + WindowsApplicationLaunchPolicy.arguments(
                for: applicationPath,
                userArguments: additionalArguments
            )
        case .installerPackage:
            ["msiexec.exe", "/i", applicationPath] + additionalArguments
        }
    }
}
