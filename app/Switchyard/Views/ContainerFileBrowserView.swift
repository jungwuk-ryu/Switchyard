import AppCore
import AppKit
import Persistence
import SwiftUI

struct ContainerFileBrowserView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let compact: Bool

    @State private var directoryURL: URL
    @State private var entries: [ContainerFileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(container: Container, initialDirectoryURL: URL?, compact: Bool) {
        self.container = container
        self.compact = compact
        let catalog = ContainerDirectoryCatalog()
        let initialURL: URL
        if let initialDirectoryURL, catalog.contains(initialDirectoryURL, in: container) {
            initialURL = initialDirectoryURL
        } else {
            initialURL = catalog.defaultDirectory(for: container)
        }
        _directoryURL = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            columnHeader

            Divider()

            if isLoading && entries.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, minHeight: compact ? 190 : 320)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Folder Unavailable",
                    systemImage: "folder.badge.questionmark",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, minHeight: compact ? 190 : 320)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("There are no visible files in this folder.")
                )
                .frame(maxWidth: .infinity, minHeight: compact ? 190 : 320)
            } else if compact {
                entryRows
            } else {
                ScrollView {
                    entryRows
                }
            }
        }
        .dashboardPanel()
        .task(id: directoryURL) {
            await loadDirectory()
        }
    }

    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(compact ? "Recent Files" : "Container Files")
                    .font(.headline)

                Spacer()

                Button {
                    store.openInFinder(directoryURL, in: container.id)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, breadcrumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }

                        Button(breadcrumb.title) {
                            directoryURL = breadcrumb.url
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Modified")
                .frame(width: 170, alignment: .leading)
            Text("Size")
                .frame(width: 74, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var entryRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(displayedEntries) { entry in
                Button {
                    if entry.isNavigable {
                        directoryURL = entry.url
                    } else {
                        store.openInFinder(entry.url, in: container.id)
                    }
                } label: {
                    ContainerFileRow(entry: entry)
                }
                .buttonStyle(.plain)
                .disabled(entry.isDirectory && !entry.isNavigable)
                .contextMenu {
                    if entry.isNavigable {
                        Button("Open Folder") {
                            directoryURL = entry.url
                        }
                    }
                    Button("Show in Finder") {
                        store.openInFinder(entry.url, in: container.id)
                    }
                    .disabled(!ContainerDirectoryCatalog().contains(entry.url, in: container))
                }

                if entry.id != displayedEntries.last?.id {
                    Divider()
                        .padding(.leading, 48)
                }
            }

            if compact && entries.count > displayedEntries.count {
                Text("\(entries.count - displayedEntries.count) more items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
            }
        }
    }

    private var displayedEntries: [ContainerFileEntry] {
        compact ? Array(entries.prefix(5)) : entries
    }

    private var breadcrumbs: [(title: String, url: URL)] {
        let rootURL = URL(fileURLWithPath: container.path, isDirectory: true).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let directoryComponents = directoryURL.standardizedFileURL.pathComponents
        guard directoryComponents.starts(with: rootComponents) else {
            return [(container.name, rootURL)]
        }

        var result: [(title: String, url: URL)] = [(container.name, rootURL)]
        var url = rootURL
        for component in directoryComponents.dropFirst(rootComponents.count) {
            url.appendPathComponent(component, isDirectory: true)
            let title = component == "drive_c" ? "C:" : component
            result.append((title, url))
        }
        return result
    }

    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        let requestedURL = directoryURL
        let container = container

        do {
            let loadedEntries = try await Task.detached(priority: .userInitiated) {
                try ContainerDirectoryCatalog().contents(of: requestedURL, in: container)
            }.value
            guard requestedURL == directoryURL else { return }
            entries = loadedEntries
        } catch {
            guard requestedURL == directoryURL else { return }
            entries = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

private struct ContainerFileRow: View {
    let entry: ContainerFileEntry

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)

                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if entry.isDirectory && !entry.isNavigable {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This link leaves the container and cannot be browsed in Switchyard.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Text(
                entry.byteCount.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                } ?? "—"
            )
            .foregroundStyle(.secondary)
            .frame(width: 74, alignment: .trailing)

            if entry.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8)
            } else {
                Color.clear.frame(width: 8, height: 1)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
