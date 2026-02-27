import SwiftUI

class SettingsHostingWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}

class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    
    private var window: SettingsHostingWindow?
    var isVisible: Bool {
        window?.isVisible ?? false
    }
    
    private init() {}
    
    func show(with settingsView: some View) {
        if window == nil {
            let contentRect = NSRect(
                x: 0,
                y: 0,
                width: UIConstants.settingsWindowWidth,
                height: UIConstants.settingsWindowHeight
            )
            
            window = SettingsHostingWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            
            window?.isReleasedWhenClosed = false
            window?.backgroundColor = NSColor.windowBackgroundColor
            window?.isOpaque = true
            window?.hasShadow = true
            window?.level = .normal
            window?.title = "Archive Settings"
            window?.titleVisibility = .visible
            window?.titlebarAppearsTransparent = false
            
            // Make sure this window is properly configured for key status
            window?.acceptsMouseMovedEvents = true
            window?.isMovableByWindowBackground = false
        }
        
        let hostingController = NSHostingController(rootView: settingsView)
        window?.contentViewController = hostingController
        
        // Position window in center of screen
        if let screenFrame = NSScreen.main?.visibleFrame {
            let windowFrame = NSRect(
                x: screenFrame.midX - UIConstants.settingsWindowWidth / 2,
                y: screenFrame.midY - UIConstants.settingsWindowHeight / 2,
                width: UIConstants.settingsWindowWidth,
                height: UIConstants.settingsWindowHeight
            )
            window?.setFrame(windowFrame, display: true)
        }
        
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func hide() {
        guard isVisible else { return }
        window?.orderOut(nil)
    }
} 
