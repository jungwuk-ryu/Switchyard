import AppCore
import CryptoKit
import Foundation

enum StarterApplicationDownloadError: LocalizedError {
    case untrustedURL(String)
    case invalidResponse(String)
    case downloadTooLarge(String)
    case invalidInstaller(String)
    case cacheWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .untrustedURL(let publisherName):
            String(
                localized: "The download left \(publisherName)'s approved installer service, so Switchyard stopped it.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidResponse(let publisherName):
            String(
                localized: "\(publisherName)'s download service did not return a complete installer.",
                bundle: SwitchyardStrings.bundle
            )
        case .downloadTooLarge(let applicationName):
            String(
                localized: "The \(applicationName) download was unexpectedly large, so Switchyard stopped before using it.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidInstaller(let applicationName):
            String(
                localized: "The downloaded file is not a complete Windows installer for \(applicationName).",
                bundle: SwitchyardStrings.bundle
            )
        case .cacheWriteFailed(let detail):
            String(
                localized: "Switchyard could not protect the downloaded installer in its private cache: \(detail)",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}

struct StarterApplicationDownloadProgress: Equatable, Sendable {
    var receivedByteCount: Int64
    var expectedByteCount: Int64?
}

private struct StarterApplicationDownloadReceipt: Codable {
    var applicationID: String
    var sourceURL: URL
    var finalURL: URL
    var byteCount: Int64
    var sha256: String
}

private final class StarterApplicationRedirectValidator: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    let starter: StarterApplication

    init(starter: StarterApplication) {
        self.starter = starter
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, starter.trustsDownloadURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct StarterApplicationDownloader: @unchecked Sendable {
    private let fileManager: FileManager
    private let cacheRoot: URL

    init(
        fileManager: FileManager = .default,
        cacheRoot: URL = StarterApplicationDownloader.defaultCacheRoot()
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot
    }

    func download(
        _ starter: StarterApplication,
        progress: @escaping @Sendable (StarterApplicationDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard starter.trustsDownloadURL(starter.downloadURL) else {
            throw StarterApplicationDownloadError.untrustedURL(starter.publisherName)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectValidator = StarterApplicationRedirectValidator(starter: starter)
        let session = URLSession(
            configuration: configuration,
            delegate: redirectValidator,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(from: starter.downloadURL)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let finalURL = response.url,
              starter.trustsDownloadURL(finalURL) else {
            throw StarterApplicationDownloadError.invalidResponse(starter.publisherName)
        }
        if response.expectedContentLength > starter.maximumDownloadBytes {
            throw StarterApplicationDownloadError.downloadTooLarge(starter.displayName)
        }
        let expectedByteCount = response.expectedContentLength > 0
            ? response.expectedContentLength
            : nil
        progress(
            StarterApplicationDownloadProgress(
                receivedByteCount: 0,
                expectedByteCount: expectedByteCount
            )
        )

        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("switchyard-installer-\(UUID().uuidString).download")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw StarterApplicationDownloadError.cacheWriteFailed(
                String(
                    localized: "Could not create a temporary download file.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let temporaryHandle: FileHandle
        do {
            temporaryHandle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            throw StarterApplicationDownloadError.cacheWriteFailed(error.localizedDescription)
        }
        do {
            var receivedByteCount: Int64 = 0
            var lastReportedByteCount: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                receivedByteCount += 1
                guard receivedByteCount <= starter.maximumDownloadBytes else {
                    throw StarterApplicationDownloadError.downloadTooLarge(
                        starter.displayName
                    )
                }
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 {
                    try Task.checkCancellation()
                    try temporaryHandle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if receivedByteCount - lastReportedByteCount >= 512 * 1_024 {
                        progress(
                            StarterApplicationDownloadProgress(
                                receivedByteCount: receivedByteCount,
                                expectedByteCount: expectedByteCount
                            )
                        )
                        lastReportedByteCount = receivedByteCount
                    }
                }
            }
            if !buffer.isEmpty {
                try temporaryHandle.write(contentsOf: buffer)
            }
            try temporaryHandle.synchronize()
            try temporaryHandle.close()
            progress(
                StarterApplicationDownloadProgress(
                    receivedByteCount: receivedByteCount,
                    expectedByteCount: expectedByteCount
                )
            )
        } catch {
            try? temporaryHandle.close()
            throw error
        }

        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let byteCount = Int64(values.fileSize ?? 0)
        guard values.isRegularFile == true, byteCount >= 2 else {
            throw StarterApplicationDownloadError.invalidInstaller(starter.displayName)
        }
        guard byteCount <= starter.maximumDownloadBytes else {
            throw StarterApplicationDownloadError.downloadTooLarge(starter.displayName)
        }
        guard starter.hasExpectedInstallerHeader(at: temporaryURL) else {
            throw StarterApplicationDownloadError.invalidInstaller(starter.displayName)
        }

        do {
            let directory = cacheDirectory(for: starter)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard directory.standardizedFileURL.resolvingSymlinksInPath()
                    == directory.standardizedFileURL else {
                throw StarterApplicationDownloadError.cacheWriteFailed(
                    String(
                        localized: "The installer cache contains an unexpected symbolic link.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let stagedURL = directory.appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: stagedURL) }
            try fileManager.copyItem(at: temporaryURL, to: stagedURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)

            let digest = try sha256Hex(for: stagedURL)
            let receipt = StarterApplicationDownloadReceipt(
                applicationID: starter.id,
                sourceURL: starter.downloadURL,
                finalURL: finalURL,
                byteCount: byteCount,
                sha256: digest
            )
            let receiptData = try JSONEncoder().encode(receipt)

            let installerURL = cachedInstallerURL(for: starter)
            if fileManager.fileExists(atPath: installerURL.path) {
                _ = try fileManager.replaceItemAt(installerURL, withItemAt: stagedURL)
            } else {
                try fileManager.moveItem(at: stagedURL, to: installerURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installerURL.path)
            try receiptData.write(to: receiptURL(for: starter), options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: receiptURL(for: starter).path
            )

            guard trustedCachedInstaller(for: starter)?.standardizedFileURL == installerURL.standardizedFileURL else {
                throw StarterApplicationDownloadError.invalidInstaller(starter.displayName)
            }
            return installerURL
        } catch let error as StarterApplicationDownloadError {
            throw error
        } catch {
            throw StarterApplicationDownloadError.cacheWriteFailed(error.localizedDescription)
        }
    }

    func trustedCachedInstaller(for starter: StarterApplication) -> URL? {
        let installerURL = cachedInstallerURL(for: starter)
        let receiptURL = receiptURL(for: starter)
        guard cacheDirectory(for: starter).standardizedFileURL.resolvingSymlinksInPath()
                == cacheDirectory(for: starter).standardizedFileURL,
              let receiptValues = try? receiptURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              receiptValues.isRegularFile == true,
              receiptValues.isSymbolicLink != true,
              let receiptData = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(
                StarterApplicationDownloadReceipt.self,
                from: receiptData
              ),
              receipt.applicationID == starter.id,
              starter.trustsDownloadURL(receipt.sourceURL),
              starter.trustsDownloadURL(receipt.finalURL),
              receipt.byteCount >= 2,
              receipt.byteCount <= starter.maximumDownloadBytes,
              let values = try? installerURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) == receipt.byteCount,
              starter.hasExpectedInstallerHeader(at: installerURL),
              (try? sha256Hex(for: installerURL)) == receipt.sha256 else {
            return nil
        }
        return installerURL
    }

    private func cacheDirectory(for starter: StarterApplication) -> URL {
        cacheRoot.appendingPathComponent(starter.id, isDirectory: true)
    }

    private func cachedInstallerURL(for starter: StarterApplication) -> URL {
        cacheDirectory(for: starter)
            .appendingPathComponent("\(starter.installerBaseName).\(starter.installerFileExtension)")
    }

    private func receiptURL(for starter: StarterApplication) -> URL {
        cacheDirectory(for: starter).appendingPathComponent("download-receipt.json")
    }

    private func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultCacheRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Installers", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("Switchyard-Installers", isDirectory: true)
    }
}
