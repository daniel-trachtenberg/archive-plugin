import SwiftUI

class UploadHostingWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}

class UploadWindowManager {
    static let shared = UploadWindowManager()
    
    private var window: UploadHostingWindow?
    
    private init() {}
    
    func show(with uploadView: some View) {
        if window == nil {
            let contentRect = NSRect(
                x: 0,
                y: 0,
                width: UIConstants.uploadWindowWidth,
                height: UIConstants.uploadWindowHeight
            )
            
            window = UploadHostingWindow(
                contentRect: contentRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            window?.isReleasedWhenClosed = false
            window?.backgroundColor = .clear
            window?.isOpaque = false
            window?.hasShadow = true
            window?.level = .normal
            window?.titleVisibility = .hidden
            window?.titlebarAppearsTransparent = true
            
            // Make sure this window is properly configured for key status
            window?.acceptsMouseMovedEvents = true
            window?.isMovableByWindowBackground = true
        }
        
        let hostingController = NSHostingController(rootView: uploadView)
        window?.contentViewController = hostingController
        
        // Position window in center of screen
        if let screenFrame = NSScreen.main?.visibleFrame {
            let windowFrame = NSRect(
                x: screenFrame.midX - UIConstants.uploadWindowWidth / 2,
                y: screenFrame.midY - UIConstants.uploadWindowHeight / 2,
                width: UIConstants.uploadWindowWidth,
                height: UIConstants.uploadWindowHeight
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
