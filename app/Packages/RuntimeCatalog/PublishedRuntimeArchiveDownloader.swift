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

enum PublishedRuntimeArchiveDownloadError: LocalizedError, Equatable, Sendable {
    case exceedsSizeLimit(
        expectedByteCount: UInt64,
        maximumByteCount: UInt64,
        observedByteCount: UInt64
    )

    var errorDescription: String? {
        String(
            localized: "The downloaded runtime size does not match its release manifest.",
            bundle: SwitchyardStrings.bundle
        )
    }
}

typealias PublishedRuntimeURLSessionFactory = @Sendable (
    URLSessionConfiguration,
    URLSessionDelegate
) -> URLSession

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

final class PublishedRuntimeArchiveDownloader: NSObject, URLSessionDataDelegate,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private static let defaultProgressIncrement: UInt64 = 512 * 1_024
    private static let defaultMaximumByteCount: UInt64 = 4 * 1_024 * 1_024 * 1_024

    private let configuration: URLSessionConfiguration
    private let expectedByteCount: UInt64
    private let maximumByteCount: UInt64
    private let minimumProgressIncrement: UInt64
    private let progress: @Sendable (UInt64) -> Void
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let sessionFactory: PublishedRuntimeURLSessionFactory
    private let lock = NSLock()

    private var continuation: CheckedContinuation<PublishedRuntimeArchiveDownloadResult, any Error>?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var downloadedFileURL: URL?
    private var response: URLResponse?
    private var cancellationRequested = false
    private var pendingTerminalError: (any Error)?
    private var lastReportedByteCount: UInt64 = 0

    init(
        configuration: URLSessionConfiguration,
        expectedByteCount: UInt64,
        maximumByteCount: UInt64 = defaultMaximumByteCount,
        minimumProgressIncrement: UInt64 = defaultProgressIncrement,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        sessionFactory: @escaping PublishedRuntimeURLSessionFactory = {
            configuration,
            delegate in
            URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        },
        progress: @escaping @Sendable (UInt64) -> Void
    ) {
        self.configuration = configuration
        self.expectedByteCount = expectedByteCount
        self.maximumByteCount = maximumByteCount
        self.minimumProgressIncrement = minimumProgressIncrement
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
            ?? fileManager.temporaryDirectory
        self.sessionFactory = sessionFactory
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
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let error = sizeError(for: response.expectedContentLength) {
            let shouldFinish = recordTerminalError(error)
            completionHandler(.cancel)
            dataTask.cancel()
            if shouldFinish {
                finish(throwing: error)
            }
            return
        }

        lock.lock()
        let shouldBecomeDownload = continuation != nil
            && !cancellationRequested
            && pendingTerminalError == nil
        if shouldBecomeDownload {
            self.response = response
        }
        lock.unlock()

        completionHandler(shouldBecomeDownload ? .becomeDownload : .cancel)
        if !shouldBecomeDownload {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didBecome downloadTask: URLSessionDownloadTask
    ) {
        lock.lock()
        let shouldContinue = continuation != nil
            && !cancellationRequested
            && pendingTerminalError == nil
        if shouldContinue {
            task = downloadTask
        }
        lock.unlock()

        if !shouldContinue {
            downloadTask.cancel()
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
        let receivedByteCount = UInt64(totalBytesWritten)
        if receivedByteCount > sizeLimit {
            let error = sizeError(observedByteCount: receivedByteCount)
            let shouldFinish = recordTerminalError(error)
            downloadTask.cancel()
            if shouldFinish {
                finish(throwing: error)
            }
            return
        }

        lock.lock()
        let shouldReport = !cancellationRequested
            && pendingTerminalError == nil
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
        if let error = sizeError(for: downloadTask.response?.expectedContentLength) {
            let shouldFinish = recordTerminalError(error)
            downloadTask.cancel()
            if shouldFinish {
                finish(throwing: error)
            }
            return
        }

        let observedByteCount: UInt64
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                finish(throwing: URLError(.cannotCreateFile))
                return
            }
            observedByteCount = UInt64(fileSize)
        } catch {
            finish(throwing: error)
            return
        }
        if observedByteCount > sizeLimit {
            let error = sizeError(observedByteCount: observedByteCount)
            let shouldFinish = recordTerminalError(error)
            downloadTask.cancel()
            if shouldFinish {
                finish(throwing: error)
            }
            return
        }

        let ownedURL = temporaryDirectory
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
        guard continuation != nil,
              !cancellationRequested,
              pendingTerminalError == nil else {
            lock.unlock()
            try? fileManager.removeItem(at: ownedURL)
            return
        }
        downloadedFileURL = ownedURL
        response = response ?? downloadTask.response
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let terminalError = recordedTerminalError {
            finish(throwing: terminalError)
            return
        }
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

    private var recordedTerminalError: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return pendingTerminalError
    }

    private var sizeLimit: UInt64 {
        min(expectedByteCount, maximumByteCount)
    }

    private func sizeError(
        for expectedContentLength: Int64?
    ) -> PublishedRuntimeArchiveDownloadError? {
        guard let expectedContentLength, expectedContentLength >= 0 else {
            return nil
        }
        let observedByteCount = UInt64(expectedContentLength)
        guard observedByteCount > sizeLimit else {
            return nil
        }
        return sizeError(observedByteCount: observedByteCount)
    }

    private func sizeError(
        observedByteCount: UInt64
    ) -> PublishedRuntimeArchiveDownloadError {
        .exceedsSizeLimit(
            expectedByteCount: expectedByteCount,
            maximumByteCount: maximumByteCount,
            observedByteCount: observedByteCount
        )
    }

    @discardableResult
    private func recordTerminalError(_ error: any Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if continuation != nil,
           !cancellationRequested,
           pendingTerminalError == nil {
            pendingTerminalError = error
            return true
        }
        return false
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
        let session = sessionFactory(configuration, self)
        let task = session.dataTask(with: url)
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
        pendingTerminalError = nil
        return completion
    }
}
