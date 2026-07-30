import Foundation
import Testing
@testable import RuntimeCatalog

@Suite(.serialized)
struct PublishedRuntimeArchiveDownloaderLimitTests {
    @Test("rejects a Content-Length above the expected size before body delivery")
    func rejectsContentLengthAboveExpectedSize() async throws {
        let fixture = try ArchiveLimitFixture(
            declaredContentLength: 9,
            chunks: [Data(repeating: 1, count: 9)],
            firstChunkDelay: .milliseconds(200)
        )
        defer { fixture.remove() }
        let downloader = fixture.makeDownloader(
            expectedByteCount: 8,
            maximumByteCount: 100
        )

        do {
            let result = try await downloader.download(from: fixture.url)
            try? FileManager.default.removeItem(at: result.fileURL)
            Issue.record("An oversized response unexpectedly completed")
        } catch let error as PublishedRuntimeArchiveDownloadError {
            #expect(
                error == .exceedsSizeLimit(
                    expectedByteCount: 8,
                    maximumByteCount: 100,
                    observedByteCount: 9
                )
            )
        }

        await fixture.probe.waitUntilStopped()
        let snapshot = fixture.probe.snapshot()
        #expect(snapshot.reportedProgress.isEmpty)
        #expect(snapshot.sentChunkCount <= 1)
        #expect(try fixture.ownedTemporaryFiles().isEmpty)
    }

    @Test("rejects a Content-Length above the absolute archive limit")
    func rejectsContentLengthAboveMaximumSize() async throws {
        let fixture = try ArchiveLimitFixture(
            declaredContentLength: 9,
            chunks: [Data(repeating: 1, count: 9)],
            firstChunkDelay: .milliseconds(200)
        )
        defer { fixture.remove() }
        let downloader = fixture.makeDownloader(
            expectedByteCount: 100,
            maximumByteCount: 8
        )

        do {
            let result = try await downloader.download(from: fixture.url)
            try? FileManager.default.removeItem(at: result.fileURL)
            Issue.record("A response above the absolute limit unexpectedly completed")
        } catch let error as PublishedRuntimeArchiveDownloadError {
            #expect(
                error == .exceedsSizeLimit(
                    expectedByteCount: 100,
                    maximumByteCount: 8,
                    observedByteCount: 9
                )
            )
        }

        await fixture.probe.waitUntilStopped()
        let snapshot = fixture.probe.snapshot()
        #expect(snapshot.reportedProgress.isEmpty)
        #expect(snapshot.sentChunkCount <= 1)
        #expect(try fixture.ownedTemporaryFiles().isEmpty)
    }

    @Test("cancels a chunked body on the first observed byte above the limit")
    func cancelsChunkedBodyAtLimit() async throws {
        let fixture = try ArchiveLimitFixture(
            declaredContentLength: nil,
            chunks: [
                Data(repeating: 1, count: 128 * 1_024),
                Data(repeating: 2, count: 128 * 1_024),
                Data(repeating: 3, count: 1),
                Data(repeating: 4, count: 128 * 1_024)
            ]
        )
        defer { fixture.remove() }
        let downloader = fixture.makeDownloader(
            expectedByteCount: 256 * 1_024,
            maximumByteCount: 512 * 1_024
        )

        do {
            let result = try await downloader.download(from: fixture.url)
            try? FileManager.default.removeItem(at: result.fileURL)
            Issue.record("An oversized chunked body unexpectedly completed")
        } catch PublishedRuntimeArchiveDownloadError.exceedsSizeLimit(
            let expectedByteCount,
            let maximumByteCount,
            let observedByteCount
        ) {
            #expect(expectedByteCount == 256 * 1_024)
            #expect(maximumByteCount == 512 * 1_024)
            #expect(observedByteCount > 256 * 1_024)
        }

        await fixture.probe.waitUntilStopped()
        let snapshot = fixture.probe.snapshot()
        #expect(snapshot.sentByteCount < 384 * 1_024 + 1)
        #expect(snapshot.stopCount == 1)
        #expect(try fixture.ownedTemporaryFiles().isEmpty)
    }

    @Test("does not trust a smaller declared length when the body exceeds it")
    func cancelsBodyThatExceedsLyingContentLength() async throws {
        let fixture = try ArchiveLimitFixture(
            declaredContentLength: 256 * 1_024,
            chunks: [
                Data(repeating: 1, count: 128 * 1_024),
                Data(repeating: 2, count: 128 * 1_024),
                Data(repeating: 3, count: 1),
                Data(repeating: 4, count: 128 * 1_024)
            ]
        )
        defer { fixture.remove() }
        let downloader = fixture.makeDownloader(
            expectedByteCount: 256 * 1_024,
            maximumByteCount: 512 * 1_024
        )

        do {
            let result = try await downloader.download(from: fixture.url)
            try? FileManager.default.removeItem(at: result.fileURL)
            Issue.record("A body larger than its Content-Length unexpectedly completed")
        } catch PublishedRuntimeArchiveDownloadError.exceedsSizeLimit(
            let expectedByteCount,
            let maximumByteCount,
            let observedByteCount
        ) {
            #expect(expectedByteCount == 256 * 1_024)
            #expect(maximumByteCount == 512 * 1_024)
            #expect(observedByteCount > 256 * 1_024)
        }

        await fixture.probe.waitUntilStopped()
        #expect(fixture.probe.snapshot().stopCount == 1)
        #expect(try fixture.ownedTemporaryFiles().isEmpty)
    }

    @Test("task cancellation cancels the active transfer and reports CancellationError")
    func taskCancellationCancelsActiveTransfer() async throws {
        let fixture = try ArchiveLimitFixture(
            declaredContentLength: 1_024 * 1_024,
            chunks: Array(
                repeating: Data(repeating: 1, count: 128 * 1_024),
                count: 8
            )
        )
        defer { fixture.remove() }
        let (progress, progressContinuation) = AsyncStream<UInt64>.makeStream()
        let downloader = fixture.makeDownloader(
            expectedByteCount: 1_024 * 1_024,
            maximumByteCount: 2 * 1_024 * 1_024
        ) { byteCount in
            progressContinuation.yield(byteCount)
        }
        let download = Task {
            try await downloader.download(from: fixture.url)
        }

        for await byteCount in progress where byteCount > 0 {
            download.cancel()
            break
        }
        progressContinuation.finish()

        do {
            let result = try await download.value
            try? FileManager.default.removeItem(at: result.fileURL)
            Issue.record("A cancelled transfer unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        await fixture.probe.waitUntilStopped()
        let snapshot = fixture.probe.snapshot()
        #expect(snapshot.stopCount == 1)
        #expect(snapshot.sentChunkCount < 8)
        #expect(try fixture.ownedTemporaryFiles().isEmpty)
    }
}

private struct ArchiveLimitProtocolPlan: @unchecked Sendable {
    var declaredContentLength: Int?
    var chunks: [Data]
    var firstChunkDelay: Duration
    var probe: ArchiveLimitTransferProbe
}

private final class ArchiveLimitURLProtocol: URLProtocol, @unchecked Sendable {
    private static let plansLock = NSLock()
    private nonisolated(unsafe) static var plans: [URL: ArchiveLimitProtocolPlan] = [:]

    private let stateLock = NSLock()
    private var isStopped = false

    static func register(_ plan: ArchiveLimitProtocolPlan, for url: URL) {
        plansLock.lock()
        plans[url] = plan
        plansLock.unlock()
    }

    static func unregister(_ url: URL) {
        plansLock.lock()
        plans[url] = nil
        plansLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "runtime-archive-limit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let plan = Self.plan(for: url),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: plan.declaredContentLength.map {
                    ["Content-Length": String($0)]
                }
              ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        DispatchQueue.global().asyncAfter(
            deadline: .now() + plan.firstChunkDelay.dispatchInterval
        ) { [weak self] in
            self?.sendChunk(at: 0, from: plan)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let wasAlreadyStopped = isStopped
        isStopped = true
        stateLock.unlock()

        if !wasAlreadyStopped,
           let url = request.url,
           let plan = Self.plan(for: url) {
            plan.probe.recordStop()
        }
    }

    private static func plan(for url: URL) -> ArchiveLimitProtocolPlan? {
        plansLock.lock()
        defer { plansLock.unlock() }
        return plans[url]
    }

    private func sendChunk(at index: Int, from plan: ArchiveLimitProtocolPlan) {
        stateLock.lock()
        let shouldStop = isStopped
        stateLock.unlock()
        guard !shouldStop else { return }

        guard index < plan.chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let chunk = plan.chunks[index]
        plan.probe.recordSentChunk(byteCount: chunk.count)
        client?.urlProtocol(self, didLoad: chunk)
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(40)
        ) { [weak self] in
            self?.sendChunk(at: index + 1, from: plan)
        }
    }
}

private final class ArchiveLimitTransferProbe: @unchecked Sendable {
    struct Snapshot {
        var sentByteCount: Int
        var sentChunkCount: Int
        var stopCount: Int
        var reportedProgress: [UInt64]
    }

    private let lock = NSLock()
    private var sentByteCount = 0
    private var sentChunkCount = 0
    private var stopCount = 0
    private var reportedProgress: [UInt64] = []
    private let stoppedStream: AsyncStream<Void>
    private let stoppedContinuation: AsyncStream<Void>.Continuation

    init() {
        (stoppedStream, stoppedContinuation) = AsyncStream.makeStream()
    }

    func recordSentChunk(byteCount: Int) {
        lock.lock()
        sentByteCount += byteCount
        sentChunkCount += 1
        lock.unlock()
    }

    func recordStop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
        stoppedContinuation.yield()
        stoppedContinuation.finish()
    }

    func recordProgress(_ byteCount: UInt64) {
        lock.lock()
        reportedProgress.append(byteCount)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            sentByteCount: sentByteCount,
            sentChunkCount: sentChunkCount,
            stopCount: stopCount,
            reportedProgress: reportedProgress
        )
    }

    func waitUntilStopped() async {
        for await _ in stoppedStream {
            return
        }
    }
}

private struct ArchiveLimitFixture {
    var url: URL
    var temporaryDirectory: URL
    var probe: ArchiveLimitTransferProbe

    init(
        declaredContentLength: Int?,
        chunks: [Data],
        firstChunkDelay: Duration = .milliseconds(25)
    ) throws {
        let identifier = UUID().uuidString
        url = try #require(
            URL(
                string: "https://runtime-archive-limit.test/\(identifier).zip"
            )
        )
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "switchyard-archive-limit-\(identifier)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        probe = ArchiveLimitTransferProbe()
        ArchiveLimitURLProtocol.register(
            ArchiveLimitProtocolPlan(
                declaredContentLength: declaredContentLength,
                chunks: chunks,
                firstChunkDelay: firstChunkDelay,
                probe: probe
            ),
            for: url
        )
    }

    func makeDownloader(
        expectedByteCount: UInt64,
        maximumByteCount: UInt64,
        progress: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) -> PublishedRuntimeArchiveDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveLimitURLProtocol.self]
        return PublishedRuntimeArchiveDownloader(
            configuration: configuration,
            expectedByteCount: expectedByteCount,
            maximumByteCount: maximumByteCount,
            minimumProgressIncrement: 1,
            temporaryDirectory: temporaryDirectory,
            progress: { byteCount in
                probe.recordProgress(byteCount)
                progress(byteCount)
            }
        )
    }

    func ownedTemporaryFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
    }

    func remove() {
        ArchiveLimitURLProtocol.unregister(url)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let components = self.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        let nanoseconds = seconds * 1_000_000_000
            + attoseconds / 1_000_000_000
        return .nanoseconds(Int(nanoseconds))
    }
}
