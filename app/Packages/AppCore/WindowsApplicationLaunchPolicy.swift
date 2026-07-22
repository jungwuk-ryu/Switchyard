import Foundation

public enum WindowsApplicationLaunchPolicy {
    private static let battleNetExecutableNames: Set<String> = [
        "battle.net launcher.exe",
        "battle.net.exe",
    ]

    private static let battleNetDisplayArguments = [
        "--high-dpi-support=1",
        "--force-device-scale-factor=1",
    ]

    public static func arguments(
        for executablePath: String,
        userArguments: [String]
    ) -> [String] {
        guard battleNetExecutableNames.contains(executableName(for: executablePath)) else {
            return userArguments
        }

        var arguments = userArguments
        for compatibilityArgument in battleNetDisplayArguments {
            let optionName = compatibilityArgument.split(separator: "=", maxSplits: 1).first.map(String.init)
                ?? compatibilityArgument
            guard !arguments.contains(where: { argument in
                argument == optionName || argument.hasPrefix("\(optionName)=")
            }) else {
                continue
            }
            arguments.append(compatibilityArgument)
        }
        return arguments
    }

    private static func executableName(for path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map { $0.lowercased() }
            ?? ""
    }
}
