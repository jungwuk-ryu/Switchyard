import AppCore
import Combine
import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine]

    init(lines: [LogLine] = []) {
        self.lines = lines
    }

    func replace(with lines: [LogLine]) {
        self.lines = lines
    }

    func recent(for containerID: UUID, limit: Int) -> [LogLine] {
        guard limit > 0 else { return [] }

        var result: [LogLine] = []
        result.reserveCapacity(limit)
        for line in lines where line.containerID == containerID {
            result.append(line)
            if result.count == limit {
                break
            }
        }
        return result
    }
}
