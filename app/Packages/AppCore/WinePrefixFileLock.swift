import Darwin
import Foundation

public enum WinePrefixFileLockMode: Sendable {
    case shared
    case exclusive
}

public final class WinePrefixFileLock: @unchecked Sendable {
    public static let fileName = ".switchyard-prefix.lock"

    private let stateLock = NSLock()
    private var descriptor: Int32

    public init(prefixPath: String, mode: WinePrefixFileLockMode) throws {
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

        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        while flock(openedDescriptor, operation) != 0 {
            if errno == EINTR { continue }
            let error = Self.posixError()
            Darwin.close(openedDescriptor)
            throw error
        }
        descriptor = openedDescriptor
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
