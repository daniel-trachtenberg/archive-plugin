import SwiftUI
import HotKey

private final class HotkeyBridge: ObservableObject {
    @Published var searchKeyboardShortcut: KeyboardShortcut
    @Published var uploadKeyboardShortcut: KeyboardShortcut
    @Published var settingsKeyboardShortcut: KeyboardShortcut

    @Published var searchSignal: Int = 0
    @Published var uploadSignal: Int = 0

    private var searchHotkey: HotKey?
    private var uploadHotkey: HotKey?
    private var shortcutsObserver: NSObjectProtocol?

    init() {
        searchKeyboardShortcut = SettingsService.shared.getShortcut(for: .search).keyboardShortcut
        uploadKeyboardShortcut = SettingsService.shared.getShortcut(for: .upload).keyboardShortcut
        settingsKeyboardShortcut = SettingsService.shared.getShortcut(for: .settings).keyboardShortcut

        reloadShortcutsAndHotkeys()

        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: .archiveShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadShortcutsAndHotkeys()
        }
    }

    deinit {
        if let shortcutsObserver {
            NotificationCenter.default.removeObserver(shortcutsObserver)
        }
    }

    private func reloadShortcutsAndHotkeys() {
        let searchShortcut = SettingsService.shared.getShortcut(for: .search)
        let uploadShortcut = SettingsService.shared.getShortcut(for: .upload)
        let settingsShortcut = SettingsService.shared.getShortcut(for: .settings)

        searchKeyboardShortcut = searchShortcut.keyboardShortcut
        uploadKeyboardShortcut = uploadShortcut.keyboardShortcut
        settingsKeyboardShortcut = settingsShortcut.keyboardShortcut

        configureGlobalHotKeys(searchShortcut: searchShortcut, uploadShortcut: uploadShortcut)
    }

    private func configureGlobalHotKeys(searchShortcut: ShortcutDefinition, uploadShortcut: ShortcutDefinition) {
        searchHotkey = searchShortcut.makeHotKey()
        searchHotkey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.searchSignal += 1
            }
        }

        uploadHotkey = uploadShortcut.makeHotKey()
        uploadHotkey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.uploadSignal += 1
            }
        }
    }
}

@main
struct ArchiveMacApp: App {
    @StateObject private var hotkeyBridge = HotkeyBridge()

    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var isUploadViewShowing: Bool = false
    @State private var isSettingsViewShowing: Bool = false

    private static var hasScheduledOnboarding = false

    // Menu constants
    private let menuWidth: CGFloat = 150
    private let menuPadding: CGFloat = 8

    init() {
        if !Self.hasScheduledOnboarding, !SettingsService.shared.hasCompletedOnboarding() {
            Self.hasScheduledOnboarding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let onboardingView = OnboardingView()
                OnboardingWindowManager.shared.show(with: onboardingView)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            VStack {
                Button("Search Files", action: searchFiles)
                    .keyboardShortcut(hotkeyBridge.searchKeyboardShortcut)

                Button("Upload Files", action: uploadFiles)
                    .keyboardShortcut(hotkeyBridge.uploadKeyboardShortcut)

                Divider()

                Button("Settings") {
                    isSettingsViewShowing = true
                    showSettingsWindow()
                }
                .keyboardShortcut(hotkeyBridge.settingsKeyboardShortcut)

                Button("Onboarding") {
                    showOnboardingWindow()
                }

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
        .onChange(of: isSearching) {
            if isSearching {
                showSearchWindow()
            }
        }
        .onChange(of: isUploadViewShowing) {
            if isUploadViewShowing {
                showUploadWindow()
            }
        }
        .onChange(of: isSettingsViewShowing) {
            if isSettingsViewShowing {
                showSettingsWindow()
            }
        }
        .onChange(of: hotkeyBridge.searchSignal) { _, _ in
            searchFiles()
        }
        .onChange(of: hotkeyBridge.uploadSignal) { _, _ in
            uploadFiles()
        }
    }

    private func searchFiles() {
        isSearching = true
        showSearchWindow()
    }

    private func uploadFiles() {
        isUploadViewShowing = true
        showUploadWindow()
    }

    private func showSearchWindow() {
        let searchView = SearchView(
            searchText: $searchText,
            isSearching: $isSearching
        )

        SearchWindowManager.shared.show(with: searchView)
    }

    private func showUploadWindow() {
        let uploadView = UploadView(
            isUploadViewShowing: $isUploadViewShowing
        )

        UploadWindowManager.shared.show(with: uploadView)
    }

    private func showSettingsWindow() {
        let settingsView = SettingsView(
            isSettingsViewShowing: $isSettingsViewShowing
        )

        SettingsWindowManager.shared.show(with: settingsView)
    }

    private func showOnboardingWindow() {
        let onboardingView = OnboardingView()
        OnboardingWindowManager.shared.show(with: onboardingView)
    }
}
