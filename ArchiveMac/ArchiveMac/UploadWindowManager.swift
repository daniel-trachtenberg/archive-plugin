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
    var isVisible: Bool {
        window?.isVisible ?? false
    }
    
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
            window?.level = .floating
            window?.title = "Upload Files"
            window?.titleVisibility = .hidden
            window?.titlebarAppearsTransparent = true
            window?.animationBehavior = .utilityWindow
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
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
                y: screenFrame.maxY - UIConstants.uploadWindowHeight - 150,
                width: UIConstants.uploadWindowWidth,
                height: UIConstants.uploadWindowHeight
            )
            window?.setFrame(windowFrame, display: true)
        }
        
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func hide() {
        guard isVisible else { return }
        window?.orderOut(nil)
    }
}
