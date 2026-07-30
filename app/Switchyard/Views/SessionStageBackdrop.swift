import AppCore
import CoreGraphics
import ImageIO
import SwiftUI

struct SessionStageBackdrop: View {
    let container: Container

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var backgroundImage: LoadedSessionBackground?
    @State private var backgroundImageLoader = LatestAsyncValueLoader<String>()

    var body: some View {
        ZStack {
            defaultGradient

            if let backgroundImage {
                Image(decorative: backgroundImage.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(reduceTransparency ? 1 : 1.035)
                    .blur(
                        radius: reduceTransparency
                            ? 0
                            : container.sessionAppearance.blurRadius
                    )
                    .transition(.opacity)
            }

            Color.black.opacity(container.sessionAppearance.dimOpacity)

            lowerGlow
        }
        .clipped()
        .ignoresSafeArea()
        .task(id: backgroundIdentity) {
            let requestedIdentity = backgroundIdentity
            let relativePath = container.sessionAppearance.backgroundImageRelativePath
            let containerPath = container.path
            await backgroundImageLoader.load(
                request: requestedIdentity,
                operation: { _ in
                    await SessionBackgroundImageLoader.load(
                        relativePath: relativePath,
                        containerPath: containerPath
                    )
                },
                isCurrent: { identity in
                    identity == backgroundIdentity
                },
                publish: { loadedImage in
                    backgroundImage = loadedImage
                }
            )
        }
        .accessibilityHidden(true)
    }

    private var backgroundIdentity: String {
        [
            container.path,
            container.sessionAppearance.backgroundImageRelativePath ?? "",
            container.lastModified.timeIntervalSinceReferenceDate.description,
        ].joined(separator: "\u{0}")
    }

    private var defaultGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.018, green: 0.03, blue: 0.055),
                    Color(red: 0.025, green: 0.055, blue: 0.105),
                    Color(red: 0.035, green: 0.075, blue: 0.145),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.3, blue: 0.62).opacity(0.25),
                    .clear,
                ],
                center: UnitPoint(x: 0.45, y: 0.61),
                startRadius: 30,
                endRadius: 560
            )

            RadialGradient(
                colors: [
                    Color(red: 0.18, green: 0.35, blue: 0.66).opacity(0.13),
                    .clear,
                ],
                center: UnitPoint(x: 0.84, y: 0.43),
                startRadius: 20,
                endRadius: 420
            )
        }
    }

    private var lowerGlow: some View {
        VStack {
            Spacer()
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.blue.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 150)
                .blur(radius: reduceTransparency ? 0 : 32)
                .offset(y: 42)
        }
    }
}

private struct LoadedSessionBackground: @unchecked Sendable {
    let image: CGImage
}

private enum SessionBackgroundImageLoader {
    static func load(
        relativePath: String?,
        containerPath: String
    ) async -> LoadedSessionBackground? {
        guard let relativePath else { return nil }
        return await Task.detached(priority: .utility) {
            let containerURL = URL(
                fileURLWithPath: containerPath,
                isDirectory: true
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()
            let candidateURL = containerURL
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard candidateURL.path.hasPrefix(containerURL.path + "/"),
                  let source = CGImageSourceCreateWithURL(
                    candidateURL as CFURL,
                    [
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceShouldAllowFloat: true,
                    ] as CFDictionary
                  ) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3_200,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            return LoadedSessionBackground(image: image)
        }.value
    }
}
