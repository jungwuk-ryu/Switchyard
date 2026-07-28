import Darwin
import Foundation

/// Host-side resource totals for the trusted processes that make up one Wine session.
///
/// These values describe the macOS processes associated with the session. They are
/// not guest-only Windows process accounting.
struct WineSessionResourceSnapshot: Equatable, Sendable {
    /// Sum of the macOS physical footprint for every sampled process.
    ///
    /// This is `nil` when the footprint could not be read for one or more of the
    /// sampled processes. Showing an incomplete sum would make the session look
    /// smaller than it is, so callers should fall back to resident memory.
    let physicalFootprintBytes: UInt64?
    let residentMemoryBytes: UInt64
    let virtualMemoryBytes: UInt64
    let threadCount: UInt64
    let sampledProcessCount: Int
    let footprintSampledProcessCount: Int
    let sampledAt: Date

    var isEmpty: Bool {
        sampledProcessCount == 0
    }

    var hasCompletePhysicalFootprint: Bool {
        physicalFootprintBytes != nil &&
            footprintSampledProcessCount == sampledProcessCount &&
            sampledProcessCount > 0
    }
}

struct WineSessionResourceMetricsService: Sendable {
    struct ProcessSample: Equatable, Sendable {
        let physicalFootprintBytes: UInt64?
        let residentMemoryBytes: UInt64
        let virtualMemoryBytes: UInt64
        let threadCount: UInt64
    }

    typealias ProcessSampler = @Sendable (pid_t) -> ProcessSample?

    private let processSampler: ProcessSampler
    private let now: @Sendable () -> Date

    init(
        processSampler: @escaping ProcessSampler = Self.sampleProcess,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processSampler = processSampler
        self.now = now
    }

    /// Samples an already trusted set of host process identifiers for one container.
    ///
    /// A process can disappear between discovery and sampling, and macOS can deny
    /// access to individual processes. Those entries are skipped without failing the
    /// rest of the session sample.
    func sample(processIDs: Set<pid_t>) -> WineSessionResourceSnapshot {
        var physicalFootprintBytes: UInt64 = 0
        var residentMemoryBytes: UInt64 = 0
        var virtualMemoryBytes: UInt64 = 0
        var threadCount: UInt64 = 0
        var sampledProcessCount = 0
        var footprintSampledProcessCount = 0

        for processID in processIDs where processID > 0 {
            guard let process = processSampler(processID) else {
                continue
            }
            if let footprint = process.physicalFootprintBytes {
                physicalFootprintBytes = Self.saturatingAdd(
                    physicalFootprintBytes,
                    footprint
                )
                footprintSampledProcessCount = Self.saturatingAdd(
                    footprintSampledProcessCount,
                    1
                )
            }
            residentMemoryBytes = Self.saturatingAdd(
                residentMemoryBytes,
                process.residentMemoryBytes
            )
            virtualMemoryBytes = Self.saturatingAdd(
                virtualMemoryBytes,
                process.virtualMemoryBytes
            )
            threadCount = Self.saturatingAdd(threadCount, process.threadCount)
            sampledProcessCount = Self.saturatingAdd(sampledProcessCount, 1)
        }

        return WineSessionResourceSnapshot(
            physicalFootprintBytes: footprintSampledProcessCount == sampledProcessCount &&
                sampledProcessCount > 0
                ? physicalFootprintBytes
                : nil,
            residentMemoryBytes: residentMemoryBytes,
            virtualMemoryBytes: virtualMemoryBytes,
            threadCount: threadCount,
            sampledProcessCount: sampledProcessCount,
            footprintSampledProcessCount: footprintSampledProcessCount,
            sampledAt: now()
        )
    }

    private static func sampleProcess(processID: pid_t) -> ProcessSample? {
        var taskInfo = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let bytesWritten = proc_pidinfo(
            processID,
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            expectedSize
        )
        guard bytesWritten >= expectedSize else {
            return nil
        }

        return ProcessSample(
            physicalFootprintBytes: physicalFootprint(processID: processID),
            residentMemoryBytes: taskInfo.pti_resident_size,
            virtualMemoryBytes: taskInfo.pti_virtual_size,
            threadCount: UInt64(max(0, taskInfo.pti_threadnum))
        )
    }

    /// Returns the kernel's physical-footprint accounting for a process.
    ///
    /// `proc_pid_rusage` is a public macOS API. Physical footprint is a closer
    /// match for the memory macOS charges to a process than RSS, but it is still
    /// host-process accounting: it does not expose a separate GPU-memory total
    /// and can differ from Activity Monitor's grouping and attribution.
    private static func physicalFootprint(processID: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            let buffer = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                processID,
                RUSAGE_INFO_V4,
                buffer
            )
        }
        guard result == 0 else {
            return nil
        }
        return usage.ri_phys_footprint
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}
