import Darwin
import Foundation

public enum WineCallbackRequestCleanup {
    public static let staleRequestAge: TimeInterval = 24 * 60 * 60

    /// Removes callback request files that can no longer belong to a live helper invocation.
    ///
    /// Cleanup is deliberately best-effort. The bridge root and its `Requests` child must be
    /// canonical, non-symlink directories owned by `ownerUserID`. Entries are opened relative to
    /// the verified directory and checked again immediately before removal so an unexpected path
    /// or file replacement is left untouched.
    @discardableResult
    public static func removeStaleRequests(
        inBridgeRoot bridgeRootURL: URL,
        now: Date = Date(),
        staleAfter: TimeInterval = staleRequestAge
    ) -> Int {
        removeStaleRequests(
            inBridgeRoot: bridgeRootURL,
            now: now,
            staleAfter: staleAfter,
            ownerUserID: getuid()
        )
    }

    @discardableResult
    static func removeStaleRequests(
        inBridgeRoot bridgeRootURL: URL,
        now: Date,
        staleAfter: TimeInterval,
        ownerUserID: uid_t
    ) -> Int {
        guard bridgeRootURL.isFileURL,
              now.timeIntervalSince1970.isFinite,
              staleAfter.isFinite,
              staleAfter > 0 else {
            return 0
        }

        let standardizedRootURL = bridgeRootURL.standardizedFileURL
        guard standardizedRootURL.path == bridgeRootURL.path,
              standardizedRootURL.path
                == bridgeRootURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            return 0
        }

        let rootDescriptor = Darwin.open(
            standardizedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return 0 }
        defer { Darwin.close(rootDescriptor) }

        guard let rootIdentity = verifiedDirectoryIdentity(
            descriptor: rootDescriptor,
            path: standardizedRootURL.path,
            ownerUserID: ownerUserID
        ) else {
            return 0
        }

        let requestsDescriptor = Darwin.openat(
            rootDescriptor,
            "Requests",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard requestsDescriptor >= 0 else { return 0 }
        defer { Darwin.close(requestsDescriptor) }

        guard let requestsIdentity = verifiedChildDirectoryIdentity(
            descriptor: requestsDescriptor,
            parentDescriptor: rootDescriptor,
            name: "Requests",
            ownerUserID: ownerUserID
        ) else {
            return 0
        }

        let enumerationDescriptor = Darwin.dup(requestsDescriptor)
        guard enumerationDescriptor >= 0,
              let directory = Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 {
                Darwin.close(enumerationDescriptor)
            }
            return 0
        }
        defer { Darwin.closedir(directory) }

        let cutoff = now.timeIntervalSince1970 - staleAfter
        var removedCount = 0
        while let entry = Darwin.readdir(directory) {
            let name = directoryEntryName(entry)
            guard isCanonicalRequestFilename(name) else { continue }

            let fileDescriptor = name.withCString {
                Darwin.openat(
                    requestsDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard fileDescriptor >= 0 else { continue }

            let shouldRemove = isEligibleRequest(
                fileDescriptor: fileDescriptor,
                name: name,
                requestsDescriptor: requestsDescriptor,
                rootDescriptor: rootDescriptor,
                rootPath: standardizedRootURL.path,
                rootIdentity: rootIdentity,
                requestsIdentity: requestsIdentity,
                ownerUserID: ownerUserID,
                cutoff: cutoff
            )
            let removed: Bool
            if shouldRemove {
                removed = name.withCString {
                    Darwin.unlinkat(requestsDescriptor, $0, 0) == 0
                }
            } else {
                removed = false
            }
            Darwin.close(fileDescriptor)
            if removed {
                removedCount += 1
            }
        }
        return removedCount
    }

    static func isCanonicalRequestFilename(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 41,
              bytes.suffix(5).elementsEqual(".json".utf8) else {
            return false
        }

        let hyphenOffsets: Set<Int> = [8, 13, 18, 23]
        for offset in 0..<36 {
            if hyphenOffsets.contains(offset) {
                guard bytes[offset] == Character("-").asciiValue else { return false }
            } else {
                let byte = bytes[offset]
                guard (48...57).contains(byte)
                        || (65...70).contains(byte)
                        || (97...102).contains(byte) else {
                    return false
                }
            }
        }
        return true
    }

    private static func verifiedDirectoryIdentity(
        descriptor: Int32,
        path: String,
        ownerUserID: uid_t
    ) -> FileIdentity? {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              Darwin.lstat(path, &pathStatus) == 0,
              isOwnedDirectory(descriptorStatus, ownerUserID: ownerUserID),
              sameFile(descriptorStatus, pathStatus) else {
            return nil
        }
        return FileIdentity(descriptorStatus)
    }

    private static func verifiedChildDirectoryIdentity(
        descriptor: Int32,
        parentDescriptor: Int32,
        name: String,
        ownerUserID: uid_t
    ) -> FileIdentity? {
        var descriptorStatus = stat()
        var entryStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &entryStatus,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }),
              isOwnedDirectory(descriptorStatus, ownerUserID: ownerUserID),
              sameFile(descriptorStatus, entryStatus) else {
            return nil
        }
        return FileIdentity(descriptorStatus)
    }

    private static func isEligibleRequest(
        fileDescriptor: Int32,
        name: String,
        requestsDescriptor: Int32,
        rootDescriptor: Int32,
        rootPath: String,
        rootIdentity: FileIdentity,
        requestsIdentity: FileIdentity,
        ownerUserID: uid_t,
        cutoff: TimeInterval
    ) -> Bool {
        var initialFileStatus = stat()
        var initialEntryStatus = stat()
        guard Darwin.fstat(fileDescriptor, &initialFileStatus) == 0,
              name.withCString({
                  Darwin.fstatat(
                      requestsDescriptor,
                      $0,
                      &initialEntryStatus,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }),
              isOwnedRegularFile(initialFileStatus, ownerUserID: ownerUserID),
              sameFile(initialFileStatus, initialEntryStatus),
              newestTimestamp(initialFileStatus) < cutoff else {
            return false
        }

        var finalRootStatus = stat()
        var finalRootPathStatus = stat()
        var finalRequestsStatus = stat()
        var finalFileStatus = stat()
        var finalEntryStatus = stat()
        guard Darwin.fstat(rootDescriptor, &finalRootStatus) == 0,
              Darwin.lstat(rootPath, &finalRootPathStatus) == 0,
              "Requests".withCString({
                  Darwin.fstatat(
                      rootDescriptor,
                      $0,
                      &finalRequestsStatus,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }),
              Darwin.fstat(fileDescriptor, &finalFileStatus) == 0,
              name.withCString({
                  Darwin.fstatat(
                      requestsDescriptor,
                      $0,
                      &finalEntryStatus,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }),
              rootIdentity.matchesDirectory(finalRootStatus, ownerUserID: ownerUserID),
              rootIdentity.matches(finalRootPathStatus),
              requestsIdentity.matches(finalRequestsStatus),
              requestsIdentity.matchesDirectory(finalRequestsStatus, ownerUserID: ownerUserID),
              isOwnedRegularFile(finalFileStatus, ownerUserID: ownerUserID),
              sameFile(initialFileStatus, finalFileStatus),
              sameFile(finalFileStatus, finalEntryStatus),
              newestTimestamp(finalFileStatus) < cutoff else {
            return false
        }
        return true
    }

    private static func isOwnedDirectory(_ status: stat, ownerUserID: uid_t) -> Bool {
        status.st_uid == ownerUserID && (status.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isOwnedRegularFile(_ status: stat, ownerUserID: uid_t) -> Bool {
        status.st_uid == ownerUserID
            && (status.st_mode & S_IFMT) == S_IFREG
            && status.st_nlink == 1
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func newestTimestamp(_ status: stat) -> TimeInterval {
        max(
            timestamp(status.st_mtimespec),
            timestamp(status.st_ctimespec),
            timestamp(status.st_birthtimespec)
        )
    }

    private static func timestamp(_ value: timespec) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private struct FileIdentity {
        let device: dev_t
        let inode: ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
        }

        func matches(_ status: stat) -> Bool {
            device == status.st_dev && inode == status.st_ino
        }

        func matchesDirectory(_ status: stat, ownerUserID: uid_t) -> Bool {
            matches(status)
                && status.st_uid == ownerUserID
                && (status.st_mode & S_IFMT) == S_IFDIR
        }
    }
}
