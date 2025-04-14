import SwiftUI
import HotKey

@main
struct ArchiveMacApp: App {
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var isUploadViewShowing: Bool = false
    @State private var isSettingsViewShowing: Bool = false
    
    // Define keyboard shortcuts
    private let searchKeyboardShortcut = KeyboardShortcut(.space, modifiers: [.option])
    private let uploadKeyboardShortcut = KeyboardShortcut("u", modifiers: [.option])
    private let settingsKeyboardShortcut = KeyboardShortcut(",", modifiers: [.command])
    
    // Define hotkeys
    private let searchHotkey = HotKey(key: .space, modifiers: [.option])
    private let uploadHotkey = HotKey(key: .u, modifiers: [.option])
    
    // Menu constants
    private let menuWidth: CGFloat = 150
    private let menuPadding: CGFloat = 8
    
    var body: some Scene {
        // Menu bar extra
        MenuBarExtra {
            VStack {
                Button("Search Files", action: searchFiles)
                .keyboardShortcut(searchKeyboardShortcut)
                .onAppear {
                    searchHotkey.keyDownHandler = searchFiles
                }
                
                Button("Upload Files", action: uploadFiles)
                .keyboardShortcut(uploadKeyboardShortcut)
                .onAppear {
                    uploadHotkey.keyDownHandler = uploadFiles
                }
                
                Divider()
                
                Button("Settings...") {
                    isSettingsViewShowing = true
                    showSettingsWindow()
                }
                .keyboardShortcut(settingsKeyboardShortcut)
                
                Divider()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .frame(minWidth: menuWidth)
            .padding(menuPadding)
        } label: {
            Image(systemName: "archivebox")
        }
        
        // Watch for search activation
        .onChange(of: isSearching) {
            if isSearching {
                showSearchWindow()
            }
        }
        
        // Watch for upload activation
        .onChange(of: isUploadViewShowing) {
            if isUploadViewShowing {
                showUploadWindow()
            }
        }
        
        // Watch for settings activation
        .onChange(of: isSettingsViewShowing) {
            if isSettingsViewShowing {
                showSettingsWindow()
            }
        }
    }
    
    // MARK: Button action functions
    
    func searchFiles() {
        isSearching = true
        showSearchWindow()
    }
    
    func uploadFiles() {
        isUploadViewShowing = true
        showUploadWindow()
    }
    
    // MARK: Show window functions
    
    func showSearchWindow() {
        let searchView = SearchView(
            searchText: $searchText,
            isSearching: $isSearching
        )
        
        SearchWindowManager.shared.show(with: searchView)
    }
    
    func showUploadWindow() {
        let uploadView = UploadView(
            isUploadViewShowing: $isUploadViewShowing
        )
        
        UploadWindowManager.shared.show(with: uploadView)
    }
    
    func showSettingsWindow() {
        let settingsView = SettingsView(
            isSettingsViewShowing: $isSettingsViewShowing
        )
        
        SettingsWindowManager.shared.show(with: settingsView)
    }
}
