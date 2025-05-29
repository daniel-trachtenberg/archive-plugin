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
    
    // Smart File Organizer integration
    @StateObject private var smartOrganizer = SmartFileOrganizerService.shared
    @State private var processWithOrganizer = true
    @State private var processingResults: [ProcessingResult] = []
    
    struct ProcessingResult {
        let fileName: String
        let success: Bool
        let destination: String?
        let error: String?
    }
    
    // Keep track of security-scoped bookmarks
    @State private var securityScopedBookmarks: [URL: Data] = [:]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Upload Files")
                    .font(.system(size: UIConstants.uploadTitleSize, weight: .medium))
                
                Spacer()
                
                Button(action: {
                    isUploadViewShowing = false
                    UploadWindowManager.shared.hide()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.system(size: UIConstants.uploadCloseButtonSize))
                }
                .buttonStyle(PlainButtonStyle())
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
                    // Smart Organizer toggle
                    HStack {
                        Toggle("Auto-organize", isOn: $processWithOrganizer)
                            .toggleStyle(CheckboxToggleStyle())
                            .font(.caption)
                            .disabled(!smartOrganizer.isActive)
                        
                        if !smartOrganizer.isActive {
                            Text("(Organizer inactive)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button("Clear") {
                        selectedFiles = []
                        errorMessage = nil
                        processingResults = []
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
                        processingResults = []
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
        .cornerRadius(UIConstants.windowCornerRadius)
        .shadow(radius: UIConstants.windowShadowRadius)
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
                
                if smartOrganizer.isActive {
                    Text("Files will be automatically organized")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Smart Organizer is inactive")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
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
            
            if processWithOrganizer && smartOrganizer.isActive {
                Text("Uploading and organizing files...")
                    .foregroundColor(.gray)
            } else {
                Text("Uploading files to Input folder...")
                    .foregroundColor(.gray)
            }
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
            
            if processWithOrganizer && smartOrganizer.isActive && !processingResults.isEmpty {
                VStack(spacing: 8) {
                    Text("Processing Results:")
                        .font(.headline)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(processingResults, id: \.fileName) { result in
                                HStack {
                                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(result.success ? .green : .red)
                                        .font(.caption)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.fileName)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        
                                        if let destination = result.destination {
                                            Text("→ \(destination)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        } else if let error = result.error {
                                            Text("Error: \(error)")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(height: 100)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
            } else {
                Text("\(selectedFiles.count) files have been uploaded to the Input folder")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
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
        processingResults = []
        
        // Create Input directory if it doesn't exist
        let inputFolderURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input")
        
        do {
            if !FileManager.default.fileExists(atPath: inputFolderURL.path) {
                try FileManager.default.createDirectory(at: inputFolderURL, withIntermediateDirectories: true)
            }
            
            // Create task for handling file copying
            Task {
                var copiedCount = 0
                var uploadedFiles: [URL] = []
                
                // Process each file
                for fileURL in selectedFiles {
                    let destinationURL = inputFolderURL.appendingPathComponent(fileURL.lastPathComponent)
                    
                    // Access the file using security-scoped bookmark if available
                    var didStartAccessing = false
                    if let bookmarkData = securityScopedBookmarks[fileURL] {
                        do {
                            var isStale = false
                            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, 
                                                     options: .withSecurityScope, 
                                                     relativeTo: nil, 
                                                     bookmarkDataIsStale: &isStale)
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
                        uploadedFiles.append(destinationURL)
                        
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
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                    
                    // Add a small delay to show progress animation
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                }
                
                // Process files with Smart Organizer if enabled
                if processWithOrganizer && smartOrganizer.isActive && !uploadedFiles.isEmpty {
                    await processUploadedFiles(uploadedFiles)
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
    
    private func processUploadedFiles(_ uploadedFiles: [URL]) async {
        for fileURL in uploadedFiles {
            let fileName = fileURL.lastPathComponent
            
            let success = await smartOrganizer.processFile(fileURL)
            
            await MainActor.run {
                if success {
                    // Try to determine where the file was moved
                    let recentOps = smartOrganizer.getRecentOperations()
                    if let lastOp = recentOps.first(where: { $0.sourceURL.lastPathComponent == fileName }) {
                        let destination = lastOp.destinationURL.deletingLastPathComponent().lastPathComponent
                        processingResults.append(ProcessingResult(
                            fileName: fileName,
                            success: true,
                            destination: destination,
                            error: nil
                        ))
                    } else {
                        processingResults.append(ProcessingResult(
                            fileName: fileName,
                            success: true,
                            destination: "Organized",
                            error: nil
                        ))
                    }
                } else {
                    processingResults.append(ProcessingResult(
                        fileName: fileName,
                        success: false,
                        destination: nil,
                        error: "No matching rule found"
                    ))
                }
            }
        }
    }
}

// Custom checkbox toggle style
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .blue : .gray)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
            
            configuration.label
        }
    }
}
