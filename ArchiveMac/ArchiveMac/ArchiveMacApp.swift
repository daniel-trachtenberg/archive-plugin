import SwiftUI
import AppKit

private final class HotkeyBridge: ObservableObject {
    @Published var searchKeyboardShortcut: KeyboardShortcut
    @Published var uploadKeyboardShortcut: KeyboardShortcut
    @Published var settingsKeyboardShortcut: KeyboardShortcut

    @Published var searchSignal: Int = 0
    @Published var uploadSignal: Int = 0
    @Published var settingsSignal: Int = 0

    private var shortcutsObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var becameActiveObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sessionActiveObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var retryWorkItems: [DispatchWorkItem] = []

    init() {
        searchKeyboardShortcut = SettingsService.shared.getShortcut(for: .search).keyboardShortcut
        uploadKeyboardShortcut = SettingsService.shared.getShortcut(for: .upload).keyboardShortcut
        settingsKeyboardShortcut = SettingsService.shared.getShortcut(for: .settings).keyboardShortcut

        GlobalHotKeyManager.shared.onHotKeyPressed = { [weak self] action in
            switch action {
            case .search:
                self?.searchSignal += 1
            case .upload:
                self?.uploadSignal += 1
            case .settings:
                self?.settingsSignal += 1
            }
        }

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

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadShortcutsAndHotkeys()
        }

        sessionActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadShortcutsAndHotkeys()
        }

        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadShortcutsAndHotkeys()
        }

        refreshHotkeysAfterLaunch()
    }

    deinit {
        retryWorkItems.forEach { $0.cancel() }

        if let shortcutsObserver {
            NotificationCenter.default.removeObserver(shortcutsObserver)
        }
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
        }
        if let becameActiveObserver {
            NotificationCenter.default.removeObserver(becameActiveObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let sessionActiveObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sessionActiveObserver)
        }
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
        }
    }

    private func refreshHotkeysAfterLaunch() {
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems.removeAll()

        DispatchQueue.main.async { [weak self] in
            self?.reloadShortcutsAndHotkeys()
        }

        // Re-bind repeatedly after launch to recover from early login-session timing races.
        let retryDelays: [TimeInterval] = [0.8, 2.0, 5.0, 12.0]
        for delay in retryDelays {
            let retryItem = DispatchWorkItem { [weak self] in
                self?.reloadShortcutsAndHotkeys()
            }
            retryWorkItems.append(retryItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryItem)
        }
    }

    private func reloadShortcutsAndHotkeys() {
        let preferredShortcuts: [ShortcutAction: ShortcutDefinition] = [
            .search: SettingsService.shared.getShortcut(for: .search),
            .upload: SettingsService.shared.getShortcut(for: .upload),
            .settings: SettingsService.shared.getShortcut(for: .settings)
        ]

        let fallbackShortcuts: [ShortcutAction: [ShortcutDefinition]] = [
            .search: [
                ShortcutDefinition(key: .space, modifiers: [.control, .option]),
                ShortcutDefinition(key: .space, modifiers: [.command, .shift]),
                ShortcutDefinition(key: .f, modifiers: [.control, .option])
            ],
            .upload: [
                ShortcutDefinition(key: .u, modifiers: [.control, .option]),
                ShortcutDefinition(key: .u, modifiers: [.command, .shift]),
                ShortcutDefinition(key: .i, modifiers: [.control, .option])
            ],
            .settings: [
                ShortcutDefinition(key: .comma, modifiers: [.control, .option]),
                ShortcutDefinition(key: .comma, modifiers: [.command, .option]),
                ShortcutDefinition(key: .s, modifiers: [.control, .option])
            ]
        ]

        let resolvedShortcuts = GlobalHotKeyManager.shared.rebind(
            preferredShortcuts: preferredShortcuts,
            fallbackShortcuts: fallbackShortcuts
        )

        for action in ShortcutAction.allCases {
            guard let preferred = preferredShortcuts[action] else {
                continue
            }

            let activeShortcut = resolvedShortcuts[action] ?? preferred

            if activeShortcut != preferred {
                SettingsService.shared.setShortcut(activeShortcut, for: action, notify: false)
                print("[Hotkeys] Adjusted \(action.rawValue) shortcut to \(activeShortcut.displayString) to avoid registration conflicts.")
            }

            switch action {
            case .search:
                searchKeyboardShortcut = activeShortcut.keyboardShortcut
            case .upload:
                uploadKeyboardShortcut = activeShortcut.keyboardShortcut
            case .settings:
                settingsKeyboardShortcut = activeShortcut.keyboardShortcut
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
    private static var becameActiveObserver: NSObjectProtocol?
    private static var wakeObserver: NSObjectProtocol?
    private static var sessionActiveObserver: NSObjectProtocol?
    private static var startupRetryWorkItems: [DispatchWorkItem] = []

    // Menu constants
    private let menuWidth: CGFloat = 150
    private let menuPadding: CGFloat = 8

    init() {
        if !Self.hasConfiguredBackendLifecycle {
            Self.hasConfiguredBackendLifecycle = true
            BackendService.shared.startLifecycleMonitoring()
            Self.scheduleBackendStartupRefreshes()

            Self.backendTerminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                Self.startupRetryWorkItems.forEach { $0.cancel() }
                Self.startupRetryWorkItems.removeAll()
                BackendService.shared.stopLifecycleMonitoring()
                BackendService.shared.stopManagedBackend()
            }

            Self.launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { _ in
                Self.scheduleBackendStartupRefreshes()
                Self.scheduleOnboardingIfNeeded()
            }

            Self.becameActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                BackendService.shared.startIfNeeded()
            }

            Self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                BackendService.shared.startIfNeeded()
            }

            Self.sessionActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                BackendService.shared.startIfNeeded()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Self.scheduleBackendStartupRefreshes()
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
            toggleSettingsWindow()
        }
    }

    private func searchFiles() {
        if SearchWindowManager.shared.isVisible {
            SearchWindowManager.shared.hide()
            isSearching = false
            return
        }

        isSearching = true
        showSearchWindow()
    }

    private func uploadFiles() {
        if UploadWindowManager.shared.isVisible {
            UploadWindowManager.shared.hide()
            isUploadViewShowing = false
            return
        }

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

    private func toggleSettingsWindow() {
        if SettingsWindowManager.shared.isVisible {
            isSettingsViewShowing = false
            SettingsWindowManager.shared.hide()
            return
        }

        isSettingsViewShowing = true
        showSettingsWindow()
    }

    private func showOnboardingWindow() {
        let onboardingView = OnboardingView()
        OnboardingWindowManager.shared.show(with: onboardingView)
    }

    private func checkForUpdatesFromMenu() {
        sparkleUpdater.checkForUpdates()
    }

    private static func scheduleBackendStartupRefreshes() {
        startupRetryWorkItems.forEach { $0.cancel() }
        startupRetryWorkItems.removeAll()

        BackendService.shared.startIfNeeded()

        let retryDelays: [TimeInterval] = [0.8, 2.0, 5.0, 12.0]
        for delay in retryDelays {
            let retryItem = DispatchWorkItem {
                BackendService.shared.startIfNeeded()
            }
            startupRetryWorkItems.append(retryItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryItem)
        }
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
