import Foundation
import Testing
@testable import RuntimeCatalog

private actor RuntimeInstallProgressRecorder {
    private var values: [PublishedRuntimeInstallProgress] = []

    func append(_ progress: PublishedRuntimeInstallProgress) {
        values.append(progress)
    }

    func snapshot() -> [PublishedRuntimeInstallProgress] {
        values
    }
}

private actor RuntimeDownloadStartGate {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if didStart {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class LockedRuntimeByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []

    func append(_ value: UInt64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class RuntimeArchiveTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let chunkSize = 128 * 1_024
    static let chunkCount = 8

    private let lock = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "runtime-progress.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(
                        Self.chunkSize * Self.chunkCount
                    )
                ]
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
        sendChunk(at: 0)
    }

    override func stopLoading() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }

    private func sendChunk(at index: Int) {
        lock.lock()
        let shouldStop = isStopped
        lock.unlock()
        guard !shouldStop else { return }

        guard index < Self.chunkCount else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(
            self,
            didLoad: Data(repeating: UInt8(index), count: Self.chunkSize)
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
            [weak self] in
            self?.sendChunk(at: index + 1)
        }
    }
}

private enum RuntimeArchiveLoaderTestError: Error {
    case stopped
}

private struct PublishedRuntimeTestFixture {
    var policy: PublishedRuntimePolicy
    var manifestData: Data
    var manifestResponse: URLResponse
}

@Test(.timeLimit(.minutes(1)))
func runtimeArchiveDownloaderReportsIncrementalBytes() async throws {
    let expectedByteCount = UInt64(
        RuntimeArchiveTestURLProtocol.chunkSize
            * RuntimeArchiveTestURLProtocol.chunkCount
    )
    let recorder = LockedRuntimeByteRecorder()
    let downloader = PublishedRuntimeArchiveDownloader(
        configuration: runtimeArchiveTestConfiguration(),
        expectedByteCount: expectedByteCount,
        minimumProgressIncrement: 1
    ) { receivedByteCount in
        recorder.append(receivedByteCount)
    }
    let url = try #require(
        URL(string: "https://runtime-progress.test/archive.zip")
    )

    let result = try await downloader.download(from: url)
    defer { try? FileManager.default.removeItem(at: result.fileURL) }

    let values = recorder.snapshot()
    #expect(values.count > 1)
    #expect(values == values.sorted())
    #expect(values.last == expectedByteCount)
    let fileSize = try result.fileURL.resourceValues(forKeys: [.fileSizeKey])
        .fileSize
    #expect(fileSize == Int(expectedByteCount))
}

@Test(.timeLimit(.minutes(1)))
func runtimeArchiveDownloaderCancelsTheURLSessionTask() async throws {
    let expectedByteCount = UInt64(
        RuntimeArchiveTestURLProtocol.chunkSize
            * RuntimeArchiveTestURLProtocol.chunkCount
    )
    let (progressValues, progressContinuation) = AsyncStream<UInt64>.makeStream()
    let downloader = PublishedRuntimeArchiveDownloader(
        configuration: runtimeArchiveTestConfiguration(),
        expectedByteCount: expectedByteCount,
        minimumProgressIncrement: 1
    ) { receivedByteCount in
        progressContinuation.yield(receivedByteCount)
    }
    let url = try #require(
        URL(string: "https://runtime-progress.test/cancel.zip")
    )
    let downloadTask = Task {
        try await downloader.download(from: url)
    }

    for await receivedByteCount in progressValues where receivedByteCount > 0 {
        downloadTask.cancel()
        break
    }
    progressContinuation.finish()

    var receivedCancellation = false
    do {
        _ = try await downloadTask.value
    } catch is CancellationError {
        receivedCancellation = true
    }
    #expect(receivedCancellation)
}

@Test func publishedRuntimeReportsTrustedDownloadByteProgress() async throws {
    let fixture = try makePublishedRuntimeTestFixture(archiveSize: 1_024)
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let recorder = RuntimeInstallProgressRecorder()
    let installer = PublishedRuntimeInstaller(
        fileManager: .default,
        runtimeCacheRoot: cacheRoot,
        manifestLoader: { _ in
            (fixture.manifestData, fixture.manifestResponse)
        },
        archiveLoader: { _, expectedByteCount, progress in
            #expect(expectedByteCount == 1_024)
            await progress(128)
            await progress(2_048)
            throw RuntimeArchiveLoaderTestError.stopped
        }
    )

    var stoppedAtArchive = false
    do {
        _ = try await installer.install(policy: fixture.policy) { progress in
            await recorder.append(progress)
        }
    } catch RuntimeArchiveLoaderTestError.stopped {
        stoppedAtArchive = true
    }

    #expect(stoppedAtArchive)
    #expect(
        await recorder.snapshot() == [
            .preparing,
            .downloading(receivedByteCount: 0, totalByteCount: 1_024),
            .downloading(receivedByteCount: 128, totalByteCount: 1_024),
            .downloading(receivedByteCount: 1_024, totalByteCount: 1_024)
        ]
    )
}

@Test func cancellingPublishedRuntimeDownloadReleasesInstallLock() async throws {
    let fixture = try makePublishedRuntimeTestFixture(archiveSize: 2_048)
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let recorder = RuntimeInstallProgressRecorder()
    let startGate = RuntimeDownloadStartGate()
    let installer = PublishedRuntimeInstaller(
        fileManager: .default,
        runtimeCacheRoot: cacheRoot,
        manifestLoader: { _ in
            (fixture.manifestData, fixture.manifestResponse)
        },
        archiveLoader: { _, _, progress in
            await progress(512)
            await startGate.markStarted()
            try await Task.sleep(for: .seconds(60))
            throw RuntimeArchiveLoaderTestError.stopped
        }
    )

    let installTask = Task {
        try await installer.install(policy: fixture.policy) { progress in
            await recorder.append(progress)
        }
    }
    await startGate.wait()
    installTask.cancel()

    var receivedCancellation = false
    do {
        _ = try await installTask.value
    } catch is CancellationError {
        receivedCancellation = true
    }
    #expect(receivedCancellation)
    #expect(
        await recorder.snapshot() == [
            .preparing,
            .downloading(receivedByteCount: 0, totalByteCount: 2_048),
            .downloading(receivedByteCount: 512, totalByteCount: 2_048)
        ]
    )

    let cacheEntries = try FileManager.default.contentsOfDirectory(
        at: cacheRoot,
        includingPropertiesForKeys: nil
    )
    #expect(
        !cacheEntries.contains {
            $0.lastPathComponent.hasPrefix(".install-")
        }
    )

    let secondInstaller = PublishedRuntimeInstaller(
        fileManager: .default,
        runtimeCacheRoot: cacheRoot,
        manifestLoader: { _ in
            (fixture.manifestData, fixture.manifestResponse)
        },
        archiveLoader: { _, _, _ in
            throw RuntimeArchiveLoaderTestError.stopped
        }
    )
    var secondInstallReachedArchive = false
    do {
        _ = try await secondInstaller.install(policy: fixture.policy)
    } catch RuntimeArchiveLoaderTestError.stopped {
        secondInstallReachedArchive = true
    }
    #expect(secondInstallReachedArchive)
}

private func makePublishedRuntimeTestFixture(
    archiveSize: UInt64
) throws -> PublishedRuntimeTestFixture {
    let revision = String(repeating: "a", count: 40)
    let archiveSha256 = String(repeating: "b", count: 64)
    let notarizationID = UUID().uuidString
    let manifestURL = try #require(
        URL(
            string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-progress/switchyard-runtime-release.json"
        )
    )
    let policy = PublishedRuntimePolicy(
        sourceRevision: revision,
        releaseManifestURL: manifestURL,
        developerTeamID: "M3CULMDKU3",
        archiveSha256: archiveSha256,
        archiveSize: archiveSize,
        notarizationID: notarizationID
    )
    let release = PublishedRuntimeRelease(
        schemaVersion: 1,
        runtimeID: "switchyard-runtime-progress",
        sourceRevision: revision,
        archive: "Switchyard-Wine-Runtime-progress.zip",
        archiveSha256: archiveSha256,
        archiveSize: archiveSize,
        platform: "macos",
        hostArchitecture: "x86_64",
        peArchitectures: ["i386", "x86_64"],
        developerTeamID: "M3CULMDKU3",
        notarizationStatus: "Accepted",
        notarizationID: notarizationID
    )
    let response = try #require(
        HTTPURLResponse(
            url: manifestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return PublishedRuntimeTestFixture(
        policy: policy,
        manifestData: try JSONEncoder().encode(release),
        manifestResponse: response
    )
}

private func runtimeArchiveTestConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RuntimeArchiveTestURLProtocol.self]
    return configuration
}
