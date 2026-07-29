import Foundation

enum ContainerStorageSizeServiceError: Error {
    case containerUnavailable
    case enumerationUnavailable
}

actor ContainerStorageSizeService {
    static let shared = ContainerStorageSizeService()

    func byteCount(forContainerAt containerURL: URL) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try Self.calculateByteCount(forContainerAt: containerURL)
        }.value
    }

    nonisolated static func calculateByteCount(
        forContainerAt containerURL: URL,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        let rootURL = containerURL.standardizedFileURL
        let rootValues = try? rootURL.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues?.isDirectory == true else {
            throw ContainerStorageSizeServiceError.containerUnavailable
        }

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw ContainerStorageSizeServiceError.enumerationUnavailable
        }

        var totalByteCount: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            let byteCount = values.fileSize ?? 0
            let (updatedTotal, overflow) = totalByteCount.addingReportingOverflow(
                Int64(max(0, byteCount))
            )
            totalByteCount = overflow ? Int64.max : updatedTotal
        }
        return totalByteCount
    }
}
