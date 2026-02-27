import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @Binding var isUploadViewShowing: Bool
    @State private var dragOver = false
    @State private var selectedFiles: [URL] = []
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadComplete = false
    @State private var errorMessage: String? = nil

    // Keep track of security-scoped bookmarks
    @State private var securityScopedBookmarks: [URL: Data] = [:]

    var body: some View {
        Group {
            if isUploading {
                uploadingView
            } else if uploadComplete {
                uploadCompleteView
            } else if selectedFiles.isEmpty {
                dragAndDropArea
            } else {
                selectedFilesView
            }
        }
        .padding(10)
        .frame(width: UIConstants.uploadWindowWidth, height: UIConstants.uploadWindowHeight)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: UIConstants.windowCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: UIConstants.windowCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: UIConstants.windowShadowRadius, x: 0, y: 12)
        .onExitCommand {
            closeUpload()
        }
        .onDisappear {
            isUploadViewShowing = false
        }
    }

    // Component Views

    private var dragAndDropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    dragOver ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: dragOver ? 2.5 : 2, dash: [6, 6])
                )

            VStack(spacing: 12) {
                Image(systemName: dragOver ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(dragOver ? .blue : .secondary)

                Text("Drop Files to Upload")
                    .font(.system(size: 18, weight: .semibold))

                Text("PDF, DOCX, PPTX, TXT, images and more")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button("Browse Finder") {
                    openFileDialog()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 2)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { droppedItems, _ in
            handleDroppedFiles(droppedItems)
            return true
        } isTargeted: { isTargeted in
            dragOver = isTargeted
        }
        // Fallback for older macOS versions.
        .onDrop(of: [UTType.fileURL.identifier, UTType.item.identifier, UTType.content.identifier], isTargeted: $dragOver) { providers, _ in
            handleDroppedProviders(providers)
            return true
        }
    }

    private var selectedFilesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Ready to Upload")
                    .font(.system(size: 14, weight: .semibold))

                Text("\(selectedFiles.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                Spacer(minLength: 0)

                Button("Clear") {
                    selectedFiles = []
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Upload") {
                    uploadFiles()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.system(size: UIConstants.resultSubtitleSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 2)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(selectedFiles, id: \.self) { file in
                        fileRow(for: file)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func fileRow(for file: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fileIconForURL(file))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.blue.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(file.deletingLastPathComponent().path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                selectedFiles.removeAll { $0 == file }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove file")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var uploadingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: uploadProgress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)

            Text("Uploading \(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s")")
                .font(.system(size: 15, weight: .semibold))

            Text("\(Int(uploadProgress * 100))%")
                .font(.system(size: 24, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var uploadCompleteView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("Upload Complete")
                .font(.system(size: 21, weight: .semibold))

            Text("\(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s") copied to Input")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button("Upload More") {
                    selectedFiles = []
                    uploadComplete = false
                    errorMessage = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button("Done") {
                    closeUpload()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // Helper Functions

    private func closeUpload() {
        UploadWindowManager.shared.hide()
        isUploadViewShowing = false
    }

    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        UploadWindowManager.shared.presentOpenPanel(panel) { result in
            if result == .OK {
                DispatchQueue.main.async {
                    self.selectedFiles = panel.urls
                    self.uploadComplete = false
                    self.errorMessage = nil
                }
            }
        }
    }

    private func handleDroppedFiles(_ droppedItems: [URL]) {
        // Filter to only include file URLs.
        let fileURLs = droppedItems.filter { $0.isFileURL }

        // Add only new files that aren't already in the selection.
        for url in fileURLs {
            if !selectedFiles.contains(url) {
                if url.startAccessingSecurityScopedResource() {
                    // Store a bookmark for later file access.
                    do {
                        let bookmarkData = try url.bookmarkData(
                            options: .minimalBookmark,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        securityScopedBookmarks[url] = bookmarkData
                    } catch {
                        print("Error creating bookmark for \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                    selectedFiles.append(url)
                } else {
                    print("Could not access security-scoped resource: \(url.lastPathComponent)")
                }
            }
        }

        if !fileURLs.isEmpty {
            uploadComplete = false
            errorMessage = nil
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            // Try with UTType.fileURL.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { urlData, _ in
                    if let urlData = urlData as? Data,
                       let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        DispatchQueue.main.async {
                            handleDroppedFiles([url])
                        }
                    }
                }
            }
            // Try with NSURL.
            else if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { url, _ in
                    if let fileURL = url as? URL {
                        DispatchQueue.main.async {
                            handleDroppedFiles([fileURL])
                        }
                    }
                }
            }
        }
    }

    private func fileIconForURL(_ url: URL) -> String {
        let fileExtension = url.pathExtension.lowercased()

        switch fileExtension {
        case "pdf", "doc", "docx":
            return "doc.text"
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return "photo"
        case "xls", "xlsx", "csv":
            return "tablecells"
        case "txt", "md", "rtf":
            return "text.alignleft"
        default:
            return "doc"
        }
    }

    private func uploadFiles() {
        guard !selectedFiles.isEmpty else { return }

        isUploading = true
        uploadProgress = 0
        errorMessage = nil

        // Use the configured Input directory from settings/backend.
        let inputFolderURL = URL(fileURLWithPath: SettingsService.shared.getInputFolder(), isDirectory: true)

        do {
            if !FileManager.default.fileExists(atPath: inputFolderURL.path) {
                try FileManager.default.createDirectory(at: inputFolderURL, withIntermediateDirectories: true)
            }

            // Create task for handling file copying.
            Task(priority: .utility) {
                var copiedCount = 0

                // Process each file.
                for fileURL in selectedFiles {
                    let destinationURL = uniqueDestinationURL(for: fileURL, in: inputFolderURL)

                    // Access the file using security-scoped bookmark if available.
                    var didStartAccessing = false
                    var accessedURL = fileURL
                    if let bookmarkData = securityScopedBookmarks[fileURL] {
                        do {
                            var isStale = false
                            let resolvedURL = try URL(
                                resolvingBookmarkData: bookmarkData,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale
                            )
                            accessedURL = resolvedURL
                            didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                        } catch {
                            print("Error resolving bookmark: \(error.localizedDescription)")
                        }
                    } else {
                        didStartAccessing = fileURL.startAccessingSecurityScopedResource()
                    }

                    do {
                        // Copy the file to the Input folder.
                        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
                        copiedCount += 1

                        // Update progress.
                        await MainActor.run {
                            uploadProgress = Double(copiedCount) / Double(selectedFiles.count)
                        }
                    } catch {
                        // Handle error for this file.
                        print("Error copying file \(fileURL.lastPathComponent): \(error.localizedDescription)")

                        // Update UI with error if needed.
                        await MainActor.run {
                            errorMessage = "Error uploading some files. Please try again."
                        }
                    }

                    // Stop accessing if we started.
                    if didStartAccessing {
                        accessedURL.stopAccessingSecurityScopedResource()
                    }

                    // Add a small delay to show progress animation.
                    try await Task.sleep(nanoseconds: 100_000_000)
                }

                // Update UI when complete.
                await MainActor.run {
                    isUploading = false
                    uploadComplete = true
                }
            }
        } catch {
            // Handle folder creation error.
            isUploading = false
            errorMessage = "Could not create Input folder: \(error.localizedDescription)"
            print("Error creating Input folder: \(error.localizedDescription)")
        }
    }

    private func uniqueDestinationURL(for sourceURL: URL, in directoryURL: URL) -> URL {
        let fileManager = FileManager.default
        var destinationURL = directoryURL.appendingPathComponent(sourceURL.lastPathComponent)

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return destinationURL
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var suffix = 1

        while fileManager.fileExists(atPath: destinationURL.path) {
            let candidate = ext.isEmpty ? "\(baseName)_\(suffix)" : "\(baseName)_\(suffix).\(ext)"
            destinationURL = directoryURL.appendingPathComponent(candidate)
            suffix += 1
        }

        return destinationURL
    }
}
