import SwiftUI

@main
struct ArchiveMacApp: App {
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var isUploadViewShowing: Bool = false
    @State private var isSettingsViewShowing: Bool = false
    
    // Define keyboard shortcuts
    private let searchKeyboardShortcut = KeyboardShortcut("j", modifiers: [.command, .shift])
    private let uploadKeyboardShortcut = KeyboardShortcut("u", modifiers: [.command, .shift])
    private let organizeKeyboardShortcut = KeyboardShortcut("o", modifiers: [.command, .shift])
    private let settingsKeyboardShortcut = KeyboardShortcut(",", modifiers: [.command])
    
    // Menu constants
    private let menuWidth: CGFloat = 150
    private let menuPadding: CGFloat = 8
    
    var body: some Scene {
        // Menu bar extra
        MenuBarExtra {
            VStack {
                Button("Search Files") {
                    isSearching = true
                    showSearchWindow()
                }
                .keyboardShortcut(searchKeyboardShortcut)
                
                Button("Upload File") {
                    isUploadViewShowing = true
                    showUploadWindow()
                }
                .keyboardShortcut(uploadKeyboardShortcut)
                
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
