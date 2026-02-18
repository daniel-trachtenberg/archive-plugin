import SwiftUI

final class OnboardingHostingWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

final class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()

    private var window: OnboardingHostingWindow?

    private init() {}

    func show(with onboardingView: some View) {
        if window == nil {
            let contentRect = NSRect(
                x: 0,
                y: 0,
                width: UIConstants.onboardingWindowWidth,
                height: UIConstants.onboardingWindowHeight
            )

            window = OnboardingHostingWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )

            window?.isReleasedWhenClosed = false
            window?.backgroundColor = NSColor.windowBackgroundColor
            window?.isOpaque = true
            window?.hasShadow = true
            window?.level = .normal
            window?.title = "Welcome to Archive"
            window?.titleVisibility = .visible
            window?.titlebarAppearsTransparent = false
            window?.acceptsMouseMovedEvents = true
            window?.isMovableByWindowBackground = false
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        window?.contentViewController = hostingController

        if let screenFrame = NSScreen.main?.visibleFrame {
            let windowFrame = NSRect(
                x: screenFrame.midX - UIConstants.onboardingWindowWidth / 2,
                y: screenFrame.midY - UIConstants.onboardingWindowHeight / 2,
                width: UIConstants.onboardingWindowWidth,
                height: UIConstants.onboardingWindowHeight
            )
            window?.setFrame(windowFrame, display: true)
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}
