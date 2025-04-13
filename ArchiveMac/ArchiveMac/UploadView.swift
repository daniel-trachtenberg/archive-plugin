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
            }
        }
        .onDrop(of: [UTType.item.identifier], isTargeted: $dragOver) { providers, _ in
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
    
    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { url, error in
                guard let url = url as? URL else { return }
                
                DispatchQueue.main.async {
                    if !self.selectedFiles.contains(url) {
                        self.selectedFiles.append(url)
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
        
        // Create Input directory if it doesn't exist
        let inputFolderURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input")
        
        do {
            if !FileManager.default.fileExists(atPath: inputFolderURL.path) {
                try FileManager.default.createDirectory(at: inputFolderURL, withIntermediateDirectories: true)
            }
            
            // Create task for handling file copying
            Task {
                var copiedCount = 0
                
                // Process each file
                for fileURL in selectedFiles {
                    let destinationURL = inputFolderURL.appendingPathComponent(fileURL.lastPathComponent)
                    
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
}
