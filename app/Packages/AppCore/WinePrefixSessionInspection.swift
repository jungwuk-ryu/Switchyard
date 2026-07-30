import Foundation

public enum WinePrefixInspectionState: String, Codable, Equatable, Sendable {
    case active
    case orphaned
    case inactive
}

public struct WinePrefixSessionInspection: Codable, Equatable, Sendable {
    public let state: WinePrefixInspectionState
    public let hostProcessIDs: [Int32]

    public init(
        state: WinePrefixInspectionState,
        hostProcessIDs: [Int32]
    ) {
        self.state = state
        self.hostProcessIDs = state == .inactive
            ? []
            : Array(Set(hostProcessIDs.filter { $0 > 0 })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case hostProcessIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try container.decode(WinePrefixInspectionState.self, forKey: .state),
            hostProcessIDs: try container.decode([Int32].self, forKey: .hostProcessIDs)
        )
    }
}
