import SwiftUI

// Custom hosting window that can become key window
class SearchHostingWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    override func resignKey() {
        super.resignKey()
        // Hide the window when it loses focus
        SearchWindowManager.shared.hide()
    }
}

class SearchWindowManager {
    static let shared = SearchWindowManager()
    
    private var window: SearchHostingWindow?
    private var clickMonitor: Any?
    
    var onClose: (() -> Void)?
    var isVisible: Bool {
        window?.isVisible ?? false
    }
    
    private init() {}
    
    func show(with searchView: some View) {
        if window == nil {
            let contentRect = NSRect(x: 0, y: 0, width: UIConstants.searchWindowWidth, height: UIConstants.searchWindowInitialHeight)
            window = SearchHostingWindow(
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
            window?.titleVisibility = .hidden
            window?.titlebarAppearsTransparent = true
            window?.animationBehavior = .utilityWindow
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            // Make sure this window is properly configured for key status
            window?.acceptsMouseMovedEvents = true
            window?.isMovableByWindowBackground = true
        }
        
        let hostingController = NSHostingController(rootView: searchView)
        window?.contentViewController = hostingController
        
        // Position window in center of screen
        if let screenFrame = NSScreen.main?.visibleFrame {
            let windowFrame = NSRect(
                x: screenFrame.midX - UIConstants.searchWindowWidth / 2,
                y: screenFrame.maxY - UIConstants.searchWindowInitialHeight - 120,
                width: UIConstants.searchWindowWidth,
                height: UIConstants.searchWindowInitialHeight
            )
            window?.setFrame(windowFrame, display: true)
        }
        
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless() // Ensures window appears in front
        NSApp.activate(ignoringOtherApps: true)
        
        // Setup click outside detection
        setupClickOutsideMonitoring()
    }
    
    func hide() {
        guard isVisible else { return }
        removeClickOutsideMonitoring()
        window?.orderOut(nil)
        onClose?()
    }
    
    func updateHeight(_ height: CGFloat) {
        guard let window = window else { return }
        
        var frame = window.frame
        // Save the top position of the window
        let topY = frame.origin.y + frame.size.height
        
        // Set new height
        frame.size.height = height
        
        // Maintain the same top position, adjusting origin.y accordingly
        frame.origin.y = topY - height
        
        window.setFrame(frame, display: true, animate: false)
    }
    
    
    private func setupClickOutsideMonitoring() {
        removeClickOutsideMonitoring()
        
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.window, window.isVisible else { return }
            
            let clickLocation = NSEvent.mouseLocation
            if !NSPointInRect(clickLocation, window.frame) {
                self.hide()
            }
        }
    }
    
    private func removeClickOutsideMonitoring() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
