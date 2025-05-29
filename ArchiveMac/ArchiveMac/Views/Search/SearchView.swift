import SwiftUI

struct SearchView: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    @FocusState private var isFocused: Bool
    @State private var results: [SearchResult] = []
    @State private var isLoading: Bool = false
    @State private var hoveredResultId: UUID? = nil
    
    // Explicitly define a public initializer
    init(searchText: Binding<String>, isSearching: Binding<Bool>) {
        self._searchText = searchText
        self._isSearching = isSearching
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .font(.system(size: UIConstants.searchIconSize))
                
                TextField("Search files...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: UIConstants.searchTextSize))
                    .focused($isFocused)
                    .onSubmit {
                        performSearch()
                    }
                    .onChange(of: searchText) {
                        if searchText.isEmpty {
                            results = []
                            updateWindowHeight()
                        }
                    }
                
                if isLoading {
                    ProgressView()
                        .scaleEffect(UIConstants.progressIndicatorScale)
                        .frame(width: UIConstants.progressIndicatorSize, height: UIConstants.progressIndicatorSize)
                } else if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        results = []
                        updateWindowHeight()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .font(.system(size: UIConstants.clearButtonSize))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(UIConstants.standardPadding)
            
            if !searchText.isEmpty {
                Divider()
                
                // Status message bar (only shows when no results and not empty search)
                if (isLoading || results.isEmpty) {
                    statusMessageBar
                }
                
                // Results list (only shows when we have results)
                if !results.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: UIConstants.resultItemSpacing) {
                            ForEach(results) { result in
                                resultRow(for: result)
                            }
                        }
                        .padding(.vertical, UIConstants.resultGroupVerticalPadding)
                    }
                    .frame(height: calculateResultsHeight())
                }
            }
        }
        .frame(width: UIConstants.searchWindowWidth)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(UIConstants.windowCornerRadius)
        .shadow(radius: UIConstants.windowShadowRadius)
        .onAppear {
            isFocused = true
            
            // Set callback for window close
            SearchWindowManager.shared.onClose = {
                isSearching = false
            }
        }
    }
    
    // Helper Views
    
    // A dedicated status message bar with vertically centered text
    private var statusMessageBar: some View {
        ZStack {
            // Use a background to ensure proper height
            Rectangle()
                .fill(Color.clear)
                .frame(height: UIConstants.statusBarHeight)
            
            // The centered message
            Text(isLoading ? "Searching..." : "Press Enter to search")
                .foregroundColor(.gray)
                .font(.system(size: UIConstants.statusTextSize))
        }
    }
    
    private func resultRow(for result: SearchResult) -> some View {
        // Wrap the existing HStack in a ZStack with a background
        ZStack {
            // Background that spans full width
            RoundedRectangle(cornerRadius: UIConstants.tinyPadding)
                .fill(hoveredResultId == result.id ? Color.gray.opacity(0.1) : Color.clear)
            
            // Original content
            HStack {
                Image(systemName: result.type.icon)
                    .foregroundColor(.blue)
                    .font(.system(size: UIConstants.resultIconSize))
                
                VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                    Text(result.name)
                        .fontWeight(.medium)
                        .font(.system(size: UIConstants.resultTitleSize))
                    
                    Text(result.path)
                        .font(.system(size: UIConstants.resultSubtitleSize))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                
                Spacer() // Add this to push content to the left
            }
            .padding(.horizontal, UIConstants.standardPadding)
            .padding(.vertical, UIConstants.smallPadding)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openFile(result)
        }
        .onHover { isHovered in
            hoveredResultId = isHovered ? result.id : nil
        }
        .animation(.easeInOut(duration: 0.1), value: hoveredResultId == result.id)
    }
    
    // Helper Methods
    
    private func calculateResultsHeight() -> CGFloat {
        // Height for results list, capped at maximum
        let contentHeight = CGFloat(results.count) * UIConstants.resultItemHeight + UIConstants.resultGroupVerticalPadding * 2
        return min(contentHeight, UIConstants.searchWindowMaxResultsHeight)
    }
    
    private func performSearch() {
        guard !searchText.isEmpty else {
            results = []
            updateWindowHeight()
            return
        }
        
        isLoading = true
        
        Task {
            let searchResults = await SearchService.shared.searchAsync(query: searchText)
            
            // Update UI on the main thread
            await MainActor.run {
                self.results = searchResults
                self.isLoading = false
                self.updateWindowHeight()
            }
        }
    }
    
    private func openFile(_ result: SearchResult) {
        let filePath = "\(result.path)/\(result.name)"
        let url = URL(fileURLWithPath: filePath)
        
        // Add file existence check
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            closeSearch()
        } else {
            // Handle the case where the file doesn't exist
            // You might want to show an alert or some UI feedback here
            print("File not found: \(url.path)")
        }
    }
    
    private func updateWindowHeight() {
        DispatchQueue.main.async {
            // Base height (search bar)
            let baseHeight: CGFloat = UIConstants.searchWindowInitialHeight
            
            // Divider height (if search is not empty)
            let dividerHeight: CGFloat = !searchText.isEmpty ? 1 : 0
            
            // Status bar height (if we're searching or have no results but not empty)
            let statusBarHeight: CGFloat = (!searchText.isEmpty && (isLoading || results.isEmpty)) ?
                UIConstants.statusBarHeight : 0
            
            // Results height (if we have results)
            let resultsHeight: CGFloat = (!searchText.isEmpty && !results.isEmpty) ?
                calculateResultsHeight() : 0
            
            // Calculate total height
            let newHeight = baseHeight + dividerHeight + statusBarHeight + resultsHeight
            
            SearchWindowManager.shared.updateHeight(newHeight)
        }
    }
    
    private func closeSearch() {
        SearchWindowManager.shared.hide()
    }
}
