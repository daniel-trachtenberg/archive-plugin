import SwiftUI
import HotKey
import AppKit

private final class HotkeyBridge: ObservableObject {
    @Published var searchKeyboardShortcut: KeyboardShortcut
    @Published var uploadKeyboardShortcut: KeyboardShortcut
    @Published var settingsKeyboardShortcut: KeyboardShortcut

    @Published var searchSignal: Int = 0
    @Published var uploadSignal: Int = 0
    @Published var settingsSignal: Int = 0

    private var searchHotkey: HotKey?
    private var uploadHotkey: HotKey?
    private var settingsHotkey: HotKey?
    private var shortcutsObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var becameActiveObserver: NSObjectProtocol?

    init() {
        searchKeyboardShortcut = SettingsService.shared.getShortcut(for: .search).keyboardShortcut
        uploadKeyboardShortcut = SettingsService.shared.getShortcut(for: .upload).keyboardShortcut
        settingsKeyboardShortcut = SettingsService.shared.getShortcut(for: .settings).keyboardShortcut

        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: .archiveShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadShortcutsAndHotkeys()
        }

        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHotkeysAfterLaunch()
        }

        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadShortcutsAndHotkeys()
        }

        refreshHotkeysAfterLaunch()
    }

    deinit {
        if let shortcutsObserver {
            NotificationCenter.default.removeObserver(shortcutsObserver)
        }
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
        }
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
    }

    private func refreshHotkeysAfterLaunch() {
        DispatchQueue.main.async { [weak self] in
            self?.reloadShortcutsAndHotkeys()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.reloadShortcutsAndHotkeys()
        }
    }

    private func reloadShortcutsAndHotkeys() {
        let searchShortcut = SettingsService.shared.getShortcut(for: .search)
        let uploadShortcut = SettingsService.shared.getShortcut(for: .upload)
        let settingsShortcut = SettingsService.shared.getShortcut(for: .settings)

        searchKeyboardShortcut = searchShortcut.keyboardShortcut
        uploadKeyboardShortcut = uploadShortcut.keyboardShortcut
        settingsKeyboardShortcut = settingsShortcut.keyboardShortcut

        configureGlobalHotKeys(
            searchShortcut: searchShortcut,
            uploadShortcut: uploadShortcut,
            settingsShortcut: settingsShortcut
        )
    }

    private func configureGlobalHotKeys(
        searchShortcut: ShortcutDefinition,
        uploadShortcut: ShortcutDefinition,
        settingsShortcut: ShortcutDefinition
    ) {
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

        settingsHotkey = settingsShortcut.makeHotKey()
        settingsHotkey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.settingsSignal += 1
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
    private let sparkleUpdater = SparkleUpdateController.shared

    private static var hasScheduledOnboarding = false
    private static var hasConfiguredBackendLifecycle = false
    private static var backendTerminationObserver: NSObjectProtocol?
    private static var launchObserver: NSObjectProtocol?

    // Menu constants
    private let menuWidth: CGFloat = 150
    private let menuPadding: CGFloat = 8

    init() {
        if !Self.hasConfiguredBackendLifecycle {
            Self.hasConfiguredBackendLifecycle = true
            BackendService.shared.startIfNeeded()

            Self.backendTerminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                BackendService.shared.stopManagedBackend()
            }

            Self.launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { _ in
                Self.scheduleOnboardingIfNeeded()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Self.scheduleOnboardingIfNeeded()
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

                Button("Check for Updates") {
                    checkForUpdatesFromMenu()
                }
                .disabled(!sparkleUpdater.canCheckForUpdates)

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
        .onChange(of: hotkeyBridge.settingsSignal) { _, _ in
            isSettingsViewShowing = true
            showSettingsWindow()
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

    private func checkForUpdatesFromMenu() {
        sparkleUpdater.checkForUpdates()
    }

    private static func scheduleOnboardingIfNeeded() {
        guard !hasScheduledOnboarding else {
            return
        }

        guard SettingsService.shared.shouldPresentOnboardingOnLaunch() else {
            return
        }

        hasScheduledOnboarding = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let onboardingView = OnboardingView()
            OnboardingWindowManager.shared.show(with: onboardingView)
        }
    }
}
