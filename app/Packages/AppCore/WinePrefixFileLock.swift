import Darwin
import Foundation

public enum WinePrefixFileLockMode: Sendable {
    case shared
    case exclusive
}

public enum WinePrefixFileLockAcquisitionError: LocalizedError, Equatable, Sendable {
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            "Timed out while waiting to access the Wine prefix."
        case .cancelled:
            "Stopped waiting to access the Wine prefix because the operation was cancelled."
        }
    }
}

public final class WinePrefixFileLock: @unchecked Sendable {
    public static let fileName = ".switchyard-prefix.lock"

    private let stateLock = NSLock()
    private var descriptor: Int32 = -1

    public init(prefixPath: String, mode: WinePrefixFileLockMode) throws {
        let openedDescriptor = try Self.openValidatedDescriptor(prefixPath: prefixPath)
        do {
            try Self.acquireBlocking(descriptor: openedDescriptor, mode: mode)
        } catch {
            Darwin.close(openedDescriptor)
            throw error
        }
        descriptor = openedDescriptor
    }

    public convenience init(
        prefixPath: String,
        mode: WinePrefixFileLockMode,
        acquisitionTimeout: Duration,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) throws {
        guard acquisitionTimeout >= .zero else {
            throw POSIXError(.EINVAL)
        }
        let clock = ContinuousClock()
        try self.init(
            prefixPath: prefixPath,
            mode: mode,
            acquisitionDeadline: clock.now.advanced(by: acquisitionTimeout),
            cancellationCheck: cancellationCheck
        )
    }

    public init(
        prefixPath: String,
        mode: WinePrefixFileLockMode,
        acquisitionDeadline: ContinuousClock.Instant,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) throws {
        let openedDescriptor = try Self.openValidatedDescriptor(prefixPath: prefixPath)
        do {
            try Self.acquireBounded(
                descriptor: openedDescriptor,
                mode: mode,
                deadline: acquisitionDeadline,
                cancellationCheck: cancellationCheck
            )
        } catch {
            Darwin.close(openedDescriptor)
            throw error
        }
        descriptor = openedDescriptor
    }

    private static func openValidatedDescriptor(prefixPath: String) throws -> Int32 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefixPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw POSIXError(.ENOENT)
        }

        let lockPath = URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
            .path
        let openedDescriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard openedDescriptor >= 0 else {
            throw Self.posixError()
        }
        var fileStatus = stat()
        guard Darwin.fstat(openedDescriptor, &fileStatus) == 0 else {
            let error = Self.posixError()
            Darwin.close(openedDescriptor)
            throw error
        }
        guard fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileStatus.st_nlink == 1,
              fileStatus.st_uid == geteuid() else {
            Darwin.close(openedDescriptor)
            throw POSIXError(.EPERM)
        }
        guard Darwin.fchmod(openedDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let error = Self.posixError()
            Darwin.close(openedDescriptor)
            throw error
        }

        return openedDescriptor
    }

    private static func acquireBlocking(
        descriptor: Int32,
        mode: WinePrefixFileLockMode
    ) throws {
        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw Self.posixError()
        }
    }

    private static func acquireBounded(
        descriptor: Int32,
        mode: WinePrefixFileLockMode,
        deadline: ContinuousClock.Instant,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB
        let clock = ContinuousClock()

        while true {
            guard !cancellationCheck() else {
                throw WinePrefixFileLockAcquisitionError.cancelled
            }
            if flock(descriptor, operation) == 0 {
                return
            }

            let errorNumber = errno
            let isContended = errorNumber == EWOULDBLOCK || errorNumber == EAGAIN
            guard isContended || errorNumber == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
            }
            guard clock.now < deadline else {
                throw WinePrefixFileLockAcquisitionError.timedOut
            }

            var requested = timespec(tv_sec: 0, tv_nsec: 10_000_000)
            var remaining = timespec()
            while Darwin.nanosleep(&requested, &remaining) != 0 {
                guard errno == EINTR else {
                    throw Self.posixError()
                }
                guard !cancellationCheck() else {
                    throw WinePrefixFileLockAcquisitionError.cancelled
                }
                guard clock.now < deadline else {
                    throw WinePrefixFileLockAcquisitionError.timedOut
                }
                requested = remaining
            }
        }
    }

    public func unlock() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        unlock()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
