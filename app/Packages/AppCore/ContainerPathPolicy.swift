import Foundation

public enum ContainerPathPolicy {
    public static func directoryName(for containerName: String) -> String {
        "\(stem(for: containerName)).container"
    }

    public static func occupiedDirectoryNames(
        containers: [Container],
        existingDirectoryNames: Set<String>
    ) -> Set<String> {
        existingDirectoryNames.union(
            containers.map { URL(fileURLWithPath: $0.path, isDirectory: true).lastPathComponent }
        )
    }

    public static func removingDuplicatePaths(
        from containers: [Container]
    ) -> (containers: [Container], removedNames: [String]) {
        var seenPaths: Set<String> = []
        var uniqueContainers: [Container] = []
        var removedNames: [String] = []

        for container in containers {
            let path = normalizedPath(container.path)
            guard !seenPaths.contains(path) else {
                removedNames.append(container.name)
                continue
            }

            seenPaths.insert(path)
            uniqueContainers.append(container)
        }

        return (uniqueContainers, removedNames)
    }

    public static func uniqueDirectoryName(
        for containerName: String,
        existingDirectoryNames: Set<String>
    ) -> String {
        let stem = stem(for: containerName)
        let occupiedNames = Set(existingDirectoryNames.map { $0.lowercased() })
        var candidate = "\(stem).container"
        var suffix = 2

        while occupiedNames.contains(candidate.lowercased()) {
            candidate = "\(stem)\(suffix).container"
            suffix += 1
        }

        return candidate
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func stem(for containerName: String) -> String {
        let stem = containerName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()

        return stem.isEmpty ? "Container" : stem
    }
}
