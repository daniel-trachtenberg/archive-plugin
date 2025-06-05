import Foundation
import Combine

/*
 * SmartFileOrganizerService.swift
 * 
 * Main coordinator service for the Smart File Organizer that orchestrates the complete file processing pipeline.
 * Integrates file monitoring, content extraction, semantic matching, and file operations for automated organization.
 */

// MARK: - Smart File Organizer Service

class SmartFileOrganizerService: ObservableObject {
    static let shared = SmartFileOrganizerService()
    
    @Published var isActive: Bool = false
    @Published var isProcessing: Bool = false
    @Published var currentFile: String? = nil
    @Published var processedCount: Int = 0
    
    private let fileMonitor = FileMonitoringService.shared
    private let contentExtractor = ContentExtractionService.shared
    private let vectorMatcher = VectorMatchingService.shared
    private let fileOperations = FileOperationsService.shared
    private let database = DatabaseService.shared
    
    private var cancellables = Set<AnyCancellable>() // Added for Combine subscriptions
    
    private init() {
        setupFileMonitoring() // Sets up the onFileDetected callback
        setupMonitoringStateObservation() // Sets up reactive observation of monitoring state
        start() // Attempts to start based on current settings
    }
    
    /// Set up file monitoring callbacks
    private func setupFileMonitoring() {
        fileMonitor.onFileDetected = { [weak self] fileURL in
            print("🔔 File detected by monitor: \(fileURL.lastPathComponent)")
            guard let self = self else { return }
            
            // Use the same async method that upload flow uses
            Task {
                let success = await self.processFile(fileURL)
                print(success ? "✅ File monitor processing completed successfully: \(fileURL.lastPathComponent)" : "❌ File monitor processing failed: \(fileURL.lastPathComponent)")
            }
        }
    }

    /// Sets up observation of the FileMonitoringService's state
    private func setupMonitoringStateObservation() {
        fileMonitor.$isMonitoring
            .receive(on: DispatchQueue.main) // Ensure updates are on the main thread
            .sink { [weak self] isCurrentlyMonitoringByFileMonitor in
                guard let self = self else { return }
                let settings = self.database.getSettings()
                let newOverallActiveState = isCurrentlyMonitoringByFileMonitor && settings.isFileMonitoringActive
                
                if self.isActive != newOverallActiveState {
                    self.isActive = newOverallActiveState
                    // Log the change in overall active state
                    if newOverallActiveState {
                        print("✅ Smart File Organizer is now active and monitoring input folder: \(settings.inputFolder)")
                    } else {
                        if settings.isFileMonitoringActive && !isCurrentlyMonitoringByFileMonitor {
                            // This case covers if monitoring is enabled but failed to start/stopped unexpectedly
                            print("⚠️ Smart File Organizer is configured to be active, but file monitoring is not currently running.")
                        } else if !settings.isFileMonitoringActive {
                            print("ℹ️ Smart File Organizer is inactive because monitoring is disabled in settings.")
                        } else {
                            // General case for becoming inactive, e.g., monitor explicitly stopped
                            print("ℹ️ Smart File Organizer is now inactive.")
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    /// Start the organizer service based on current settings
    private func start() {
        let settings = database.getSettings()
        print("📁 SmartFileOrganizerService attempting to start...")
        print("📂 Configured Input folder: \(settings.inputFolder)")
        print("📤 Configured Output folder: \(settings.outputFolder)")
        print("⚙️ File Monitoring should be active: \(settings.isFileMonitoringActive)")
        
        // Check if any rules are configured
        let rules = database.getAllRules()
        let activeRules = rules.filter { $0.isActive }
        print("📋 Total organization rules: \(rules.count)")
        print("✅ Active organization rules: \(activeRules.count)")
        
        if activeRules.isEmpty {
            print("⚠️ WARNING: No active organization rules configured! Files will not be organized.")
            print("💡 Please add organization rules in Settings > Rules tab")
        } else {
            print("📝 Active rules:")
            for rule in activeRules {
                print("   - \(rule.name): [\(rule.keywords.joined(separator: ", "))] → \(rule.destinationFolder)")
            }
        }
        
        // Ensure input folder exists
        if !FileManager.default.fileExists(atPath: settings.inputFolder) {
            do {
                try FileManager.default.createDirectory(atPath: settings.inputFolder, withIntermediateDirectories: true, attributes: nil)
                print("✅ Created input folder: \(settings.inputFolder)")
            } catch {
                print("❌ Failed to create input folder: \(settings.inputFolder). Error: \(error)")
                // isActive will be false due to fileMonitor.isMonitoring being false (as it won't start)
                return
            }
        }
        
        if settings.isFileMonitoringActive {
            // Attempt to start the file monitor. Its state will be observed by setupMonitoringStateObservation.
            fileMonitor.startMonitoringFromSettings()
        } else {
            // If settings say monitoring is off, ensure our state reflects that.
            // The Combine sink will also handle this if fileMonitor.isMonitoring is false.
            DispatchQueue.main.async {
                 if self.isActive { self.isActive = false } // Ensure if it was somehow true
            }
            print("ℹ️ File monitoring is disabled by settings. Smart File Organizer will not actively monitor files.")
        }
        // Note: self.isActive is now primarily managed by the Combine sink.
        // The initial state will be set once fileMonitor.$isMonitoring emits its first value.
        
        print("📊 SmartFileOrganizerService initialization completed")
    }
    
    /// Process a file through the complete organization pipeline
    func processFile(_ fileURL: URL) async -> Bool {
        print("🔄 SmartFileOrganizerService.processFile() called for: \(fileURL.lastPathComponent)")
        
        await MainActor.run {
            self.isProcessing = true
            self.currentFile = fileURL.lastPathComponent
        }
        
        let success = await performFileProcessing(fileURL)
        
        await MainActor.run {
            self.isProcessing = false
            self.currentFile = nil
            if success {
                self.processedCount += 1
            }
        }
        
        return success
    }
    
    /// Execute the complete file processing pipeline
    private func performFileProcessing(_ fileURL: URL) async -> Bool {
        print("🔄 Processing file: \(fileURL.lastPathComponent)")
        print("📂 File path: \(fileURL.path)")
        
        // Validate file access and properties
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ File does not exist: \(fileURL.path)")
            return false
        }
        
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            print("❌ File is not readable: \(fileURL.path)")
            return false
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            print("📏 File size: \(fileSize) bytes")
            print("🔒 File permissions check passed")
        } catch {
            print("❌ Could not read file attributes: \(error.localizedDescription)")
            return false
        }
        
        do {
            // Step 1: Extract content from file
            print("📄 Extracting content from: \(fileURL.lastPathComponent)")
            let extractedContent = try await contentExtractor.extractContent(from: fileURL)
            print("✅ Extracted \(extractedContent.contentLength) characters from \(fileURL.lastPathComponent)")
            
            // Step 2: Find matching rule using semantic analysis
            print("🧠 Finding matching rule for: \(fileURL.lastPathComponent)")
            guard let matchResult = vectorMatcher.findBestMatch(for: extractedContent) else {
                print("❌ No matching rule found for: \(fileURL.lastPathComponent)")
                return false
            }
            
            print("✅ Match details for \(fileURL.lastPathComponent): \(matchResult.explanation)")
            
            // Step 3: Move file to destination
            let destinationURL = URL(fileURLWithPath: matchResult.rule.destinationFolder).appendingPathComponent(fileURL.lastPathComponent)
            print("📦 Moving \(fileURL.lastPathComponent) to: \(destinationURL.path)")
            
            let operationResult = await fileOperations.moveFile(
                from: fileURL, 
                to: destinationURL,
                ruleName: matchResult.rule.name
            )
            
            if operationResult.success {
                print("✅ Successfully organized: \(fileURL.lastPathComponent)")
                return true
            } else {
                print("❌ Failed to move \(fileURL.lastPathComponent): \(operationResult.error?.localizedDescription ?? "Unknown error")")
                return false
            }
            
        } catch {
            print("❌ Processing error for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
    
    /// Get recent file operations for UI display
    func getRecentOperations(limit: Int = 10) -> [FileOperation] {
        return fileOperations.getRecentOperations(limit: limit)
    }
    
    /// Update organizer settings when configuration changes
    func updateSettings() {
        print("🔄 SmartFileOrganizerService received request to update settings...")
        let newSettings = database.getSettings()

        if newSettings.isFileMonitoringActive {
            if !fileMonitor.isMonitoring { // If monitoring is supposed to be active but isn't (e.g., was just enabled)
                print("⚙️ File monitoring was inactive or path changed, attempting to (re)start based on new settings...")
                fileMonitor.startMonitoringFromSettings() 
            } else {
                // Monitoring is already active, tell FileMonitoringService to check if its path needs updating.
                print("⚙️ File monitoring is active, requesting FileMonitoringService to update its path if needed.")
                fileMonitor.updateMonitoringFromSettings()
            }
        } else {
            if fileMonitor.isMonitoring { // If monitoring is active but setting is now disabled
                print("⚙️ File monitoring was active, but setting is now disabled. Stopping monitoring...")
                fileMonitor.stopMonitoring()
            }
        }
        // self.isActive is now managed by the Combine sink, reacting to changes in fileMonitor.isMonitoring and settings.
        // The print statement about "Monitoring active: \(self.isActive)" will be covered by the sink's logging.
        print("ℹ️ SmartFileOrganizerService finished processing settings update. Current monitoring status will be reflected by reactive updates.")
    }
    
    /// Stop the organizer service
    func stop() {
        fileMonitor.stopMonitoring() // This will trigger the Combine sink to update isActive
        print("🛑 Smart File Organizer explicitly stopped.")
        // No need to directly set self.isActive = false, Combine sink will handle it.
    }
} 