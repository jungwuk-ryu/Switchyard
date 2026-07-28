import Foundation

struct PublishedRuntimeArchiveDownloadResult: @unchecked Sendable {
    var fileURL: URL
    var response: URLResponse
}

typealias PublishedRuntimeManifestLoader = @Sendable (URL) async throws -> (Data, URLResponse)
typealias PublishedRuntimeArchiveLoader = @Sendable (
    URL,
    UInt64,
    @escaping @Sendable (UInt64) async -> Void
) async throws -> PublishedRuntimeArchiveDownloadResult

actor PublishedRuntimeDownloadProgressRelay {
    private let handler: @Sendable (UInt64) async -> Void
    private var largestReportedByteCount: UInt64 = 0
    private var isFinished = false

    init(handler: @escaping @Sendable (UInt64) async -> Void) {
        self.handler = handler
    }

    func report(_ receivedByteCount: UInt64) async {
        guard !isFinished, receivedByteCount > largestReportedByteCount else {
            return
        }
        largestReportedByteCount = receivedByteCount
        await handler(receivedByteCount)
    }

    func finish() {
        isFinished = true
    }
}

final class PublishedRuntimeArchiveDownloader: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private static let defaultProgressIncrement: UInt64 = 512 * 1_024

    private let configuration: URLSessionConfiguration
    private let expectedByteCount: UInt64
    private let minimumProgressIncrement: UInt64
    private let progress: @Sendable (UInt64) -> Void
    private let fileManager: FileManager
    private let lock = NSLock()

    private var continuation: CheckedContinuation<PublishedRuntimeArchiveDownloadResult, any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloadedFileURL: URL?
    private var response: URLResponse?
    private var cancellationRequested = false
    private var lastReportedByteCount: UInt64 = 0

    init(
        configuration: URLSessionConfiguration,
        expectedByteCount: UInt64,
        minimumProgressIncrement: UInt64 = defaultProgressIncrement,
        fileManager: FileManager = .default,
        progress: @escaping @Sendable (UInt64) -> Void
    ) {
        self.configuration = configuration
        self.expectedByteCount = expectedByteCount
        self.minimumProgressIncrement = minimumProgressIncrement
        self.fileManager = fileManager
        self.progress = progress
    }

    func download(from url: URL) async throws -> PublishedRuntimeArchiveDownloadResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startDownload(from: url, continuation: continuation)
            }
        } onCancel: {
            requestCancellation()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten >= 0 else { return }
        let receivedByteCount = min(UInt64(totalBytesWritten), expectedByteCount)

        lock.lock()
        let shouldReport = !cancellationRequested
            && continuation != nil
            && (
                receivedByteCount == expectedByteCount
                    || receivedByteCount
                        >= lastReportedByteCount + minimumProgressIncrement
            )
        if shouldReport {
            lastReportedByteCount = receivedByteCount
        }
        lock.unlock()

        if shouldReport {
            progress(receivedByteCount)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let ownedURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "switchyard-runtime-\(UUID().uuidString).download",
                isDirectory: false
            )

        do {
            try fileManager.moveItem(at: location, to: ownedURL)
        } catch {
            finish(throwing: error)
            return
        }

        lock.lock()
        guard continuation != nil, !cancellationRequested else {
            lock.unlock()
            try? fileManager.removeItem(at: ownedURL)
            return
        }
        downloadedFileURL = ownedURL
        response = downloadTask.response
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if cancellationWasRequested {
            finish(throwing: CancellationError())
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(throwing: CancellationError())
            } else {
                finish(throwing: error)
            }
            return
        }

        lock.lock()
        let result = downloadedFileURL.flatMap { fileURL in
            response.map {
                PublishedRuntimeArchiveDownloadResult(
                    fileURL: fileURL,
                    response: $0
                )
            }
        }
        lock.unlock()

        guard let result else {
            finish(throwing: URLError(.cannotCreateFile))
            return
        }
        finish(returning: result)
    }

    private var cancellationWasRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    private func startDownload(
        from url: URL,
        continuation: CheckedContinuation<PublishedRuntimeArchiveDownloadResult, any Error>
    ) {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: url)
        self.session = session
        self.task = task
        lock.unlock()

        task.resume()
    }

    private func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func finish(returning result: PublishedRuntimeArchiveDownloadResult) {
        let completion = takeCompletion(deleteDownloadedFile: false)
        completion.session?.invalidateAndCancel()
        completion.continuation?.resume(returning: result)
    }

    private func finish(throwing error: any Error) {
        let completion = takeCompletion(deleteDownloadedFile: true)
        if let downloadedFileURL = completion.downloadedFileURL {
            try? fileManager.removeItem(at: downloadedFileURL)
        }
        completion.session?.invalidateAndCancel()
        completion.continuation?.resume(throwing: error)
    }

    private func takeCompletion(
        deleteDownloadedFile: Bool
    ) -> (
        continuation: CheckedContinuation<PublishedRuntimeArchiveDownloadResult, any Error>?,
        session: URLSession?,
        downloadedFileURL: URL?
    ) {
        lock.lock()
        defer { lock.unlock() }

        let completion = (
            continuation: continuation,
            session: session,
            downloadedFileURL: deleteDownloadedFile ? downloadedFileURL : nil
        )
        continuation = nil
        session = nil
        task = nil
        downloadedFileURL = nil
        response = nil
        return completion
    }
}
