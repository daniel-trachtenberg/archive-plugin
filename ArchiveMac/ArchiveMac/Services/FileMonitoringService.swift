import Foundation
import Combine

/*
 * FileMonitoringService.swift
 * 
 * This service provides real-time file system monitoring for the Smart File Organizer.
 * It watches the user-configured input folder for new files and triggers processing
 * when files are detected.
 * 
 * Features:
 * - Continuous folder monitoring using DispatchSource
 * - Debouncing to avoid processing files that are still being written
 * - Filtering of temporary and system files
 * - Thread-safe operation with proper cleanup
 */

// MARK: - File Event Types

enum FileEvent {
    case fileAdded(URL)
    case fileModified(URL)
    case fileRemoved(URL)
}

// MARK: - Monitoring Errors

enum MonitoringError: Error {
    case invalidPath
    case permissionDenied
    case monitoringFailed
    case alreadyMonitoring
    
    var localizedDescription: String {
        switch self {
        case .invalidPath:
            return "Invalid folder path"
        case .permissionDenied:
            return "Permission denied to access folder"
        case .monitoringFailed:
            return "Failed to start folder monitoring"
        case .alreadyMonitoring:
            return "Already monitoring a folder"
        }
    }
}

// MARK: - File Monitoring Service

class FileMonitoringService: ObservableObject {
    static let shared = FileMonitoringService()
    
    // MARK: - Published Properties
    @Published var isMonitoring: Bool = false
    @Published var monitoredFolderPath: String? = nil
    @Published var lastProcessedFile: String? = nil
    @Published var processedFileCount: Int = 0
    
    // MARK: - Private Properties
    private var folderMonitor: DispatchSourceFileSystemObject?
    private var monitorQueue = DispatchQueue(label: "com.archivemac.filemonitor", qos: .userInitiated)
    private var debounceTimers: [String: Timer] = [:]
    private let debounceInterval: TimeInterval = 2.0 // Wait 2 seconds after file changes
    
    // File processing callback
    var onFileDetected: ((URL) -> Void)?
    
    // Supported file extensions for processing
    private let supportedExtensions: Set<String> = [
        "pdf", "doc", "docx", "txt", "rtf", "md",
        "jpg", "jpeg", "png", "gif", "heic", "webp",
        "xls", "xlsx", "csv", "ppt", "pptx"
    ]
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Start monitoring the specified folder
    func startMonitoring(folderPath: String) throws {
        guard !isMonitoring else {
            throw MonitoringError.alreadyMonitoring
        }
        
        let folderURL = URL(fileURLWithPath: folderPath)
        
        // Verify folder exists and is accessible
        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw MonitoringError.invalidPath
        }
        
        // Check if we can read the directory
        guard FileManager.default.isReadableFile(atPath: folderPath) else {
            throw MonitoringError.permissionDenied
        }
        
        // Create file descriptor for the folder
        let fileDescriptor = open(folderPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw MonitoringError.permissionDenied
        }
        
        // Create dispatch source for file system events
        folderMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename],
            queue: monitorQueue
        )
        
        guard let monitor = folderMonitor else {
            close(fileDescriptor)
            throw MonitoringError.monitoringFailed
        }
        
        // Set up event handler
        monitor.setEventHandler { [weak self] in
            self?.handleFolderEvent(folderURL: folderURL)
        }
        
        // Set up cancellation handler
        monitor.setCancelHandler {
            close(fileDescriptor)
        }
        
        // Start monitoring
        monitor.resume()
        
        DispatchQueue.main.async(qos: .userInitiated) {
            self.isMonitoring = true
            self.monitoredFolderPath = folderPath
        }
        
        print("Started monitoring folder: \(folderPath)")
    }
    
    /// Stop monitoring the current folder
    func stopMonitoring() {
        folderMonitor?.cancel()
        folderMonitor = nil
        
        // Cancel any pending debounce timers
        debounceTimers.values.forEach { $0.invalidate() }
        debounceTimers.removeAll()
        
        DispatchQueue.main.async(qos: .userInitiated) {
            self.isMonitoring = false
            self.monitoredFolderPath = nil
        }
        
        print("Stopped folder monitoring")
    }
    
    /// Restart monitoring with current settings
    func restartMonitoring() {
        guard let currentPath = monitoredFolderPath else { return }
        
        stopMonitoring()
        
        do {
            try startMonitoring(folderPath: currentPath)
        } catch {
            print("Failed to restart monitoring: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods
    
    private func handleFolderEvent(folderURL: URL) {
        print("📂 FileMonitoringService: Folder event detected in \(folderURL.path)")
        
        // Get current folder contents
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            
            print("📄 Found \(contents.count) items in folder")
            
            // Process each file
            for fileURL in contents {
                print("🔍 Checking file: \(fileURL.lastPathComponent)")
                processFileIfEligible(fileURL)
            }
            
        } catch {
            print("❌ Error reading folder contents: \(error.localizedDescription)")
        }
    }
    
    private func processFileIfEligible(_ fileURL: URL) {
        let filePath = fileURL.path
        let fileName = fileURL.lastPathComponent
        
        print("🔍 Processing eligibility for: \(fileName)")
        
        // Skip if not a regular file
        guard isRegularFile(fileURL) else { 
            print("⏭️ Skipping \(fileName): not a regular file")
            return 
        }
        
        // Skip temporary and system files
        guard !isTemporaryFile(fileURL) else { 
            print("⏭️ Skipping \(fileName): temporary/system file")
            return 
        }
        
        // Skip unsupported file types
        guard isSupportedFileType(fileURL) else { 
            print("⏭️ Skipping \(fileName): unsupported file type")
            return 
        }
        
        print("✅ File \(fileName) is eligible for processing")
        
        // Debounce file processing to avoid processing files that are still being written
        debounceFileProcessing(fileURL)
    }
    
    private func debounceFileProcessing(_ fileURL: URL) {
        let filePath = fileURL.path
        let fileName = fileURL.lastPathComponent
        
        print("⏱️ Debouncing file processing for: \(fileName)")
        
        // Cancel existing timer for this file
        debounceTimers[filePath]?.invalidate()
        
        // Create new timer
        let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            print("🚀 Debounce timer fired for: \(fileName)")
            self?.processFile(fileURL)
            self?.debounceTimers.removeValue(forKey: filePath)
        }
        
        debounceTimers[filePath] = timer
    }
    
    private func processFile(_ fileURL: URL) {
        let fileName = fileURL.lastPathComponent
        print("🔄 FileMonitoringService: Processing file \(fileName)")
        
        // Verify file still exists and hasn't been modified recently
        guard FileManager.default.fileExists(atPath: fileURL.path) else { 
            print("❌ File no longer exists: \(fileName)")
            return 
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                let timeSinceModification = Date().timeIntervalSince(modificationDate)
                
                print("📅 File \(fileName) last modified \(timeSinceModification) seconds ago")
                
                // Skip if file was modified very recently (might still be writing)
                guard timeSinceModification > 1.0 else { 
                    print("⏭️ File \(fileName) modified too recently, skipping")
                    return 
                }
            }
        } catch {
            print("❌ Error checking file attributes for \(fileName): \(error.localizedDescription)")
            return
        }
        
        // Update statistics
        DispatchQueue.main.async(qos: .userInitiated) {
            self.lastProcessedFile = fileURL.lastPathComponent
            self.processedFileCount += 1
        }
        
        print("📤 Triggering file processing for: \(fileName)")
        
        // Trigger file processing
        onFileDetected?(fileURL)
        
        print("✅ File processing triggered for: \(fileName)")
    }
    
    // MARK: - File Type Checking
    
    private func isRegularFile(_ fileURL: URL) -> Bool {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            return resourceValues.isRegularFile ?? false
        } catch {
            return false
        }
    }
    
    private func isTemporaryFile(_ fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent
        
        // Skip common temporary file patterns
        let temporaryPatterns = [
            "~$", // Microsoft Office temp files
            ".tmp", ".temp", ".cache",
            ".DS_Store", ".localized",
            "Thumbs.db", "desktop.ini",
            ".crdownload", ".download", // Browser downloads
            ".part", ".partial" // Partial downloads
        ]
        
        for pattern in temporaryPatterns {
            if fileName.contains(pattern) || fileName.hasPrefix(".") {
                return true
            }
        }
        
        return false
    }
    
    private func isSupportedFileType(_ fileURL: URL) -> Bool {
        let fileExtension = fileURL.pathExtension.lowercased()
        return supportedExtensions.contains(fileExtension)
    }
}

// MARK: - Settings Integration

extension FileMonitoringService {
    /// Start monitoring using the current input folder from settings
    func startMonitoringFromSettings() {
        // First, check if global monitoring is enabled
        guard SettingsService.shared.getIsFileMonitoringActive() else {
            print("ℹ️ FileMonitoringService: Start requested, but global monitoring is disabled in settings.")
            // Ensure local state reflects that it's not monitoring
            if self.isMonitoring {
                DispatchQueue.main.async(qos: .userInitiated) {
                    self.isMonitoring = false
                    self.monitoredFolderPath = nil
                }
            }
            return
        }
        
        let inputFolder = SettingsService.shared.getInputFolder()
        
        print("🔍 FileMonitoringService: Starting monitoring from settings")
        print("📁 Target folder: \(inputFolder)")
        
        do {
            try startMonitoring(folderPath: inputFolder)
            print("✅ FileMonitoringService: Successfully started monitoring")
        } catch {
            print("❌ FileMonitoringService: Failed to start monitoring - \(error.localizedDescription)")
        }
    }
    
    /// Update monitoring when settings change
    func updateMonitoringFromSettings() {
        // Check if global monitoring is enabled first
        guard SettingsService.shared.getIsFileMonitoringActive() else {
            print("ℹ️ FileMonitoringService: Update requested, but global monitoring is disabled.")
            if isMonitoring { // If it was monitoring, stop it
                print("⚙️ Stopping monitoring because global setting is now disabled.")
                stopMonitoring()
            }
            return
        }
        
        let newInputFolder = SettingsService.shared.getInputFolder()
        
        print("🔄 FileMonitoringService: Updating monitoring settings")
        print("📁 New input folder: \(newInputFolder)")
        
        // Only restart if the path has changed OR if monitoring was previously off and is now being enabled
        if monitoredFolderPath != newInputFolder || !isMonitoring {
            print("📂 Folder path changed or monitoring was re-enabled, restarting monitoring...")
            stopMonitoring() // Stop current if any, or ensure it's reset if it was off
            
            do {
                try startMonitoring(folderPath: newInputFolder) // This will re-check global setting, but it's fine
                print("✅ FileMonitoringService: Successfully updated monitoring")
            } catch {
                print("❌ FileMonitoringService: Failed to update monitoring - \(error.localizedDescription)")
            }
        } else {
            print("📂 Folder path unchanged and monitoring already active, continuing monitoring")
        }
    }
} 