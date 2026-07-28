import AppCore
import RuntimeCatalog

enum SessionRuntimeResolver {
    static func runtime(
        currentRuntime: RuntimeBuild,
        installedRuntimes: [ManagedRuntimeInstallation],
        lastRuntime: ContainerRuntimeRecord?,
        isLaunching: Bool
    ) -> RuntimeBuild {
        guard !isLaunching, let lastRuntime else {
            return currentRuntime
        }
        if currentRuntime.id == lastRuntime.runtimeID,
           matches(currentRuntime, record: lastRuntime) {
            return currentRuntime
        }

        if let exactMatch = installedRuntimes.lazy
            .map(\.runtime)
            .first(where: {
                $0.id == lastRuntime.runtimeID
                    && matches($0, record: lastRuntime)
            }) {
            return exactMatch
        }

        guard lastRuntime.sourceRevision != nil else {
            return currentRuntime
        }
        return installedRuntimes.lazy
            .map(\.runtime)
            .first(where: { matches($0, record: lastRuntime) })
            ?? currentRuntime
    }

    private static func matches(
        _ runtime: RuntimeBuild,
        record: ContainerRuntimeRecord
    ) -> Bool {
        guard runtime.patchsetID == record.patchsetID else {
            return false
        }
        guard let sourceRevision = record.sourceRevision else {
            return true
        }
        return runtime.sourceRevision == sourceRevision
    }
}
