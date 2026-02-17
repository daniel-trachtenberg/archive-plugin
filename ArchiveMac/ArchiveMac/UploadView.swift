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
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Upload Files")
                    .font(.system(size: UIConstants.uploadTitleSize, weight: .medium))
            }
            .padding(.horizontal, UIConstants.uploadHeaderPadding)
            .padding(.vertical, UIConstants.uploadHeaderVerticalPadding)
            
            Divider()
            
            // Main content
            VStack(spacing: UIConstants.uploadContentSpacing) {
                if isUploading {
                    uploadingView
                } else if uploadComplete {
                    uploadCompleteView
                } else if !selectedFiles.isEmpty {
                    selectedFilesView
                } else {
                    dragAndDropArea
                }
            }
            .padding(UIConstants.uploadContentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Footer with action buttons
            HStack {
                if errorMessage != nil {
                    Text(errorMessage!)
                        .foregroundColor(.red)
                        .font(.system(size: UIConstants.resultSubtitleSize))
                }
                
                Spacer()
                
                if !selectedFiles.isEmpty && !isUploading && !uploadComplete {
                    Button("Clear") {
                        selectedFiles = []
                        errorMessage = nil
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .controlSize(.regular)
                    
                    Button("Upload") {
                        uploadFiles()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.regular)
                } else if uploadComplete {
                    Button("Upload More") {
                        selectedFiles = []
                        uploadComplete = false
                        errorMessage = nil
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, UIConstants.uploadHeaderPadding)
            .padding(.vertical, UIConstants.uploadHeaderVerticalPadding)
            .frame(height: UIConstants.uploadFooterHeight)
        }
        .frame(width: UIConstants.uploadWindowWidth, height: UIConstants.uploadWindowHeight)
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear {
            isUploadViewShowing = false
        }
    }
    
    // Component Views
    
    private var dragAndDropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIConstants.uploadAreaCornerRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: UIConstants.uploadBorderWidth, dash: [5]))
                .foregroundColor(dragOver ? Color.blue : Color.gray.opacity(0.5))
                .frame(height: UIConstants.uploadDragAreaHeight)
                .background(Color.gray.opacity(0.05).cornerRadius(UIConstants.uploadAreaCornerRadius))
            
            VStack(spacing: UIConstants.standardPadding) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: UIConstants.uploadIconSize))
                    .foregroundColor(dragOver ? .blue : .gray)
                
                Text("Drag files here")
                    .font(.headline)
                
                Text("or")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
                Button("Select Files") {
                    openFileDialog()
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
        // First try the modern .dropDestination API (macOS 13+)
        .dropDestination(for: URL.self) { droppedItems, location in
            handleDroppedFiles(droppedItems)
            return true
        } isTargeted: { isTargeted in
            dragOver = isTargeted
        }
        // Fallback for older macOS versions
        .onDrop(of: [UTType.fileURL.identifier, UTType.item.identifier, UTType.content.identifier], isTargeted: $dragOver) { providers, _ in
            handleDroppedProviders(providers)
            return true
        }
    }
    
    private var selectedFilesView: some View {
        VStack(spacing: UIConstants.smallPadding) {
            HStack {
                Text("Selected Files")
                    .font(.headline)
                
                Spacer()
                
                Text("\(selectedFiles.count) files")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: UIConstants.uploadListItemSpacing) {
                    ForEach(selectedFiles, id: \.self) { file in
                        HStack {
                            Image(systemName: fileIconForURL(file))
                                .foregroundColor(.blue)
                                .font(.system(size: UIConstants.uploadFileIconSize))
                            
                            Text(file.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Spacer()
                            
                            Button(action: {
                                selectedFiles.removeAll { $0 == file }
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: UIConstants.uploadRemoveButtonSize))
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.vertical, UIConstants.uploadListItemVerticalPadding)
                        
                        if selectedFiles.last != file {
                            Divider()
                        }
                    }
                }
            }
        }
    }
    
    private var uploadingView: some View {
        VStack(spacing: UIConstants.uploadContentSpacing) {
            ProgressView(value: uploadProgress, total: 1.0)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(height: UIConstants.uploadProgressHeight)
            
            Text("\(Int(uploadProgress * 100))%")
                .font(.title)
                .bold()
            
            Text("Uploading files to Input folder...")
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var uploadCompleteView: some View {
        VStack(spacing: UIConstants.standardPadding) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: UIConstants.uploadCompletedIconSize))
                .foregroundColor(.green)
            
            Text("Upload Complete!")
                .font(.system(size: 24))
            
            Text("\(selectedFiles.count) files have been uploaded to the Input folder")
                .font(.system(size: 16))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Helper Functions
    
    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        panel.begin { result in
            if result == .OK {
                DispatchQueue.main.async {
                    self.selectedFiles = panel.urls
                }
            }
        }
    }
    
    private func handleDroppedFiles(_ droppedItems: [URL]) {
        // Filter to only include file URLs
        let fileURLs = droppedItems.filter { $0.isFileURL }
        
        // Add only new files that aren't already in the selection
        for url in fileURLs {
            if !selectedFiles.contains(url) {
                if url.startAccessingSecurityScopedResource() {
                    // Store a bookmark for later file access
                    do {
                        let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
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
    }
    
    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            // Try with UTType.fileURL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { urlData, error in
                    if let urlData = urlData as? Data, 
                       let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        DispatchQueue.main.async {
                            handleDroppedFiles([url])
                        }
                    }
                }
            }
            // Try with NSURL
            else if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { url, error in
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
            
            // Create task for handling file copying
            Task(priority: .utility) {
                var copiedCount = 0
                
                // Process each file
                for fileURL in selectedFiles {
                    let destinationURL = uniqueDestinationURL(for: fileURL, in: inputFolderURL)
                    
                    // Access the file using security-scoped bookmark if available
                    var didStartAccessing = false
                    var accessedURL = fileURL
                    if let bookmarkData = securityScopedBookmarks[fileURL] {
                        do {
                            var isStale = false
                            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, 
                                                     options: .withSecurityScope, 
                                                     relativeTo: nil, 
                                                     bookmarkDataIsStale: &isStale)
                            accessedURL = resolvedURL
                            didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                        } catch {
                            print("Error resolving bookmark: \(error.localizedDescription)")
                        }
                    } else {
                        didStartAccessing = fileURL.startAccessingSecurityScopedResource()
                    }
                    
                    do {
                        // Copy the file to the Input folder
                        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
                        copiedCount += 1
                        
                        // Update progress
                        await MainActor.run {
                            uploadProgress = Double(copiedCount) / Double(selectedFiles.count)
                        }
                    } catch {
                        // Handle error for this file
                        print("Error copying file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                        
                        // Update UI with error if needed
                        await MainActor.run {
                            errorMessage = "Error uploading some files. Please try again."
                        }
                    }
                    
                    // Stop accessing if we started
                    if didStartAccessing {
                        accessedURL.stopAccessingSecurityScopedResource()
                    }
                    
                    // Add a small delay to show progress animation
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                }
                
                // Update UI when complete
                await MainActor.run {
                    isUploading = false
                    uploadComplete = true
                }
            }
        } catch {
            // Handle folder creation error
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
