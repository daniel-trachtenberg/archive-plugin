import SwiftUI

struct SearchView: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool

    @FocusState private var isFocused: Bool
    @State private var results: [SearchResult] = []
    @State private var isLoading: Bool = false
    @State private var selectedResultId: UUID?
    @State private var pendingSearchTask: Task<Void, Never>?

    init(searchText: Binding<String>, isSearching: Binding<Bool>) {
        self._searchText = searchText
        self._isSearching = isSearching
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hintRow(text: "Type to search your archive")
            } else if isLoading {
                hintRow(text: "Searching...")
            } else if results.isEmpty {
                hintRow(text: "No matches")
            } else {
                resultsList
            }
        }
        .frame(width: UIConstants.searchWindowWidth)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: UIConstants.windowCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: UIConstants.windowCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: UIConstants.windowShadowRadius, x: 0, y: 12)
        .onMoveCommand(perform: handleMoveCommand)
        .onExitCommand {
            closeSearch()
        }
        .onAppear {
            isFocused = true
            SearchWindowManager.shared.onClose = {
                isSearching = false
            }
            updateWindowHeight()
        }
        .onDisappear {
            pendingSearchTask?.cancel()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: UIConstants.searchIconSize, weight: .semibold))

            TextField("Search files", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: UIConstants.searchTextSize, weight: .regular, design: .default))
                .focused($isFocused)
                .onSubmit {
                    openSelectedOrFirstResult()
                }
                .onChange(of: searchText) { _, newValue in
                    scheduleSearch(for: newValue)
                }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: UIConstants.progressIndicatorSize, height: UIConstants.progressIndicatorSize)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    results = []
                    selectedResultId = nil
                    updateWindowHeight()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: UIConstants.clearButtonSize))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var resultsList: some View {
        List(results, selection: $selectedResultId) { result in
            resultRow(for: result)
                .tag(result.id)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .frame(height: calculateResultsHeight())
        .onChange(of: results) { _, newResults in
            selectedResultId = newResults.first?.id
            updateWindowHeight()
        }
    }

    private func hintRow(text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: UIConstants.statusTextSize))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: UIConstants.statusBarHeight)
    }

    private func resultRow(for result: SearchResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.type.icon)
                .foregroundStyle(.blue)
                .font(.system(size: UIConstants.resultIconSize, weight: .medium))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: UIConstants.resultTitleSize, weight: .medium))
                    .lineLimit(1)

                Text(result.path)
                    .font(.system(size: UIConstants.resultSubtitleSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openFile(result)
        }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }

        let currentIndex: Int
        if let selectedResultId,
           let index = results.firstIndex(where: { $0.id == selectedResultId }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }

        switch direction {
        case .down:
            selectedResultId = results[min(currentIndex + 1, results.count - 1)].id
        case .up:
            selectedResultId = results[max(currentIndex - 1, 0)].id
        default:
            break
        }
    }

    private func openSelectedOrFirstResult() {
        if let selectedResultId,
           let selected = results.first(where: { $0.id == selectedResultId }) {
            openFile(selected)
            return
        }

        if let first = results.first {
            openFile(first)
            return
        }

        scheduleSearch(for: searchText)
    }

    private func scheduleSearch(for query: String) {
        pendingSearchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isLoading = false
            results = []
            selectedResultId = nil
            updateWindowHeight()
            return
        }

        isLoading = true

        pendingSearchTask = Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            let searchResults = await SearchService.shared.searchAsync(query: trimmed)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    self.results = searchResults
                    self.selectedResultId = searchResults.first?.id
                    self.isLoading = false
                    self.updateWindowHeight()
                }
            }
        }
    }

    private func calculateResultsHeight() -> CGFloat {
        let contentHeight = CGFloat(results.count) * UIConstants.resultItemHeight + UIConstants.resultGroupVerticalPadding * 2
        return min(contentHeight, UIConstants.searchWindowMaxResultsHeight)
    }

    private func openFile(_ result: SearchResult) {
        let filePath = "\(result.path)/\(result.name)"
        let url = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("File not found: \(url.path)")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
        closeSearch()
    }

    private func updateWindowHeight() {
        DispatchQueue.main.async {
            let searchBarHeight = UIConstants.searchWindowInitialHeight

            let contentHeight: CGFloat
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isLoading || results.isEmpty {
                contentHeight = UIConstants.statusBarHeight
            } else {
                contentHeight = calculateResultsHeight()
            }

            SearchWindowManager.shared.updateHeight(searchBarHeight + contentHeight)
        }
    }

    private func closeSearch() {
        SearchWindowManager.shared.hide()
    }
}
