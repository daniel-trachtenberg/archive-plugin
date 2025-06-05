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
 * - Immediate processing of newly detected files
 * - Filtering of temporary and system files
 * - Thread-safe operation with proper cleanup
 * - Only processes newly added files, not existing ones
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
    
    // Track existing files to only process new ones
    private var existingFiles: Set<String> = []
    private var isInitialScan: Bool = true
    
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
        
        // Perform initial scan to populate existing files
        performInitialScan(folderURL: folderURL)
        
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
        print("Initial scan found \(existingFiles.count) existing files")
    }
    
    /// Stop monitoring the current folder
    func stopMonitoring() {
        folderMonitor?.cancel()
        folderMonitor = nil
        
        // Reset state
        existingFiles.removeAll()
        isInitialScan = true
        
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
    
    private func performInitialScan(folderURL: URL) {
        print("📂 FileMonitoringService: Performing initial scan of \(folderURL.path)")
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            
            // Populate existing files set with file paths
            existingFiles = Set(contents.compactMap { fileURL in
                guard isRegularFile(fileURL), 
                      !isTemporaryFile(fileURL),
                      isSupportedFileType(fileURL) else {
                    return nil
                }
                return fileURL.path
            })
            
            print("📄 Initial scan found \(existingFiles.count) eligible files")
            isInitialScan = false
            
        } catch {
            print("❌ Error during initial scan: \(error.localizedDescription)")
            existingFiles.removeAll()
            isInitialScan = false
        }
    }
    
    private func handleFolderEvent(folderURL: URL) {
        print("📂 FileMonitoringService: Folder event detected in \(folderURL.path)")
        
        // Get current folder contents
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            
            // Find eligible files
            let currentEligibleFiles = Set(contents.compactMap { fileURL -> String? in
                guard isRegularFile(fileURL),
                      !isTemporaryFile(fileURL),
                      isSupportedFileType(fileURL) else {
                    return nil
                }
                return fileURL.path
            })
            
            // Find newly added files (files that weren't in existingFiles)
            let newFiles = currentEligibleFiles.subtracting(existingFiles)
            
            print("📄 Current eligible files: \(currentEligibleFiles.count)")
            print("📄 Previously tracked files: \(existingFiles.count)")
            print("🆕 New files detected: \(newFiles.count)")
            
            // Process only new files immediately
            for newFilePath in newFiles {
                let newFileURL = URL(fileURLWithPath: newFilePath)
                print("🔍 Processing new file: \(newFileURL.lastPathComponent)")
                processFileIfEligible(newFileURL)
            }
            
            // Update our tracking set
            existingFiles = currentEligibleFiles
            
        } catch {
            print("❌ Error reading folder contents: \(error.localizedDescription)")
        }
    }
    
    private func processFileIfEligible(_ fileURL: URL) {
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
        
        // Process file immediately (no debouncing)
        processFile(fileURL)
    }
    
    private func processFile(_ fileURL: URL) {
        let fileName = fileURL.lastPathComponent
        print("🔄 FileMonitoringService: Processing file \(fileName)")
        
        // Verify file still exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else { 
            print("❌ File no longer exists: \(fileName)")
            return 
        }
        
        // Basic stability check - ensure file isn't being actively written
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                let timeSinceModification = Date().timeIntervalSince(modificationDate)
                print("📅 File \(fileName) last modified \(String(format: "%.1f", timeSinceModification)) seconds ago")
                
                // Only skip if file was modified in the last 0.1 seconds (very recent)
                if timeSinceModification < 0.1 {
                    print("⏭️ File \(fileName) modified too recently, will retry shortly")
                    // Quick retry after 0.2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.processFile(fileURL)
                    }
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
        
        // Trigger file processing immediately
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