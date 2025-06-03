import Foundation
import SwiftData
import NaturalLanguage
import Combine

/*
 * DatabaseService.swift
 * 
 * Manages the SwiftData stack and provides database operations for the Smart File Organizer.
 * Handles app settings, organization rules with vector embeddings, and vector similarity operations.
 */

// MARK: - Database Errors

enum DatabaseError: Error {
    case contextSaveFailed(Error)
    case entityNotFound
    case embeddingGenerationFailed
    case invalidData
    
    var localizedDescription: String {
        switch self {
        case .contextSaveFailed(let error):
            return "Failed to save database context: \(error.localizedDescription)"
        case .entityNotFound:
            return "Required database entity not found"
        case .embeddingGenerationFailed:
            return "Failed to generate text embeddings"
        case .invalidData:
            return "Invalid data provided to database"
        }
    }
}

// MARK: - Vector Match Result

struct VectorMatchResult {
    let rule: OrganizationRule
    let similarity: Double
}

// MARK: - Database Service

class DatabaseService: ObservableObject {
    static let shared = DatabaseService()
    
    private var modelContainer: ModelContainer
    private var context: ModelContext
    private let nlEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    
    private init() {
        do {
            modelContainer = try ModelContainer(for: AppSettings.self, OrganizationRule.self)
            context = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
    
    // MARK: - Settings Management
    
    /// Get current app settings (input and output folder paths, monitoring status)
    func getSettings() -> (inputFolder: String, outputFolder: String, isFileMonitoringActive: Bool) {
        do {
            let descriptor = FetchDescriptor<AppSettings>()
            let settings = try context.fetch(descriptor).first
            
            if let settings = settings {
                return (settings.inputFolderPath, settings.outputFolderPath, settings.isFileMonitoringActive)
            } else {
                return createDefaultSettings()
            }
        } catch {
            print("Failed to fetch settings: \(error)")
            return createDefaultSettings()
        }
    }
    
    /// Update app settings with new folder paths and monitoring status
    func updateSettings(inputFolder: String, outputFolder: String, isFileMonitoringActive: Bool) {
        do {
            let descriptor = FetchDescriptor<AppSettings>()
            let settings = try context.fetch(descriptor).first
            
            if let existingSettings = settings {
                existingSettings.inputFolderPath = inputFolder
                existingSettings.outputFolderPath = outputFolder
                existingSettings.isFileMonitoringActive = isFileMonitoringActive
                existingSettings.lastModified = Date()
            } else {
                let newSettings = AppSettings(inputFolderPath: inputFolder, outputFolderPath: outputFolder, isFileMonitoringActive: isFileMonitoringActive)
                context.insert(newSettings)
            }
            
            try context.save()
        } catch {
            print("Failed to update settings: \(error)")
        }
    }
    
    /// Create default settings if none exist
    private func createDefaultSettings() -> (String, String, Bool) {
        let defaultInputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Input").path
        let defaultOutputFolder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("Output").path
        let defaultMonitoringStatus = true
        
        updateSettings(inputFolder: defaultInputFolder, outputFolder: defaultOutputFolder, isFileMonitoringActive: defaultMonitoringStatus)
        return (defaultInputFolder, defaultOutputFolder, defaultMonitoringStatus)
    }
    
    // MARK: - Organization Rules Management
    
    /// Get all organization rules, sorted by creation date
    func getAllRules() -> [OrganizationRule] {
        do {
            let descriptor = FetchDescriptor<OrganizationRule>(sortBy: [SortDescriptor(\.createdAt)])
            return try context.fetch(descriptor)
        } catch {
            print("Failed to fetch rules: \(error)")
            return []
        }
    }
    
    /// Save or update an organization rule with vector embedding
    func saveRule(_ rule: OrganizationRule) {
        do {
            // Generate and store text embedding
            if let embedding = generateTextEmbedding(for: rule.ruleDescription) {
                if let jsonData = try? JSONSerialization.data(withJSONObject: embedding) {
                    rule.textEmbedding = jsonData
                } else {
                    print("Failed to serialize embedding to JSON")
                }
            }
            
            // Insert the rule. If it's already managed, SwiftData handles this gracefully.
            context.insert(rule)
            
            try context.save()
        } catch {
            print("Failed to save rule: \(error)")
        }
    }
    
    /// Delete an organization rule by ID
    func deleteRule(withId id: UUID) {
        do {
            let descriptor = FetchDescriptor<OrganizationRule>(predicate: #Predicate { $0.id == id })
            if let rule = try context.fetch(descriptor).first {
                context.delete(rule)
                try context.save()
            }
        } catch {
            print("Failed to delete rule: \(error)")
        }
    }
    
    // MARK: - Vector Matching
    
    /// Primary function to find the best matching rule, trying filename first, then content.
    func findBestMatchingRule(forFilename filename: String, contentText: String) -> VectorMatchResult? {
        let activeRules = getAllRules().filter { $0.isActive }
        
        // Step 1: Try to match by filename embedding
        if let filenameEmbedding = generateTextEmbedding(for: filename) {
            for rule in activeRules {
                if let ruleEmbedding = getRuleEmbedding(rule: rule) {
                    let similarity = cosineSimilarity(filenameEmbedding, ruleEmbedding)
                    if similarity >= 0.7 {
                        // Filename match is strong enough
                        return VectorMatchResult(rule: rule, similarity: similarity)
                    }
                }
            }
        }
        
        // Step 2: If no strong filename match, try content embedding
        if let contentEmbedding = generateTextEmbedding(for: contentText) {
            return findBestMatchingRule(forContentEmbedding: contentEmbedding, rules: activeRules)
        }
        
        return nil // No match found by either method
    }

    /// Find the best matching rule for a given content embedding from a list of rules.
    private func findBestMatchingRule(forContentEmbedding contentEmbedding: [Double], rules: [OrganizationRule]) -> VectorMatchResult? {
        var bestMatch: VectorMatchResult? = nil
        
        for rule in rules {
            if let ruleEmbedding = getRuleEmbedding(rule: rule) {
                let similarity = cosineSimilarity(contentEmbedding, ruleEmbedding)
                
                // For content matching, we take the highest similarity without a strict threshold here,
                // as the filename match (with 0.7 threshold) is the primary filter.
                if bestMatch == nil || similarity > bestMatch!.similarity {
                    bestMatch = VectorMatchResult(rule: rule, similarity: similarity)
                }
            }
        }
        return bestMatch
    }
    
    /// Extract vector embedding from a rule's stored embedding data
    private func getRuleEmbedding(rule: OrganizationRule) -> [Double]? {
        guard let embeddingData = rule.textEmbedding else { return nil }
        
        if let embedding = try? JSONSerialization.jsonObject(with: embeddingData) as? [Double] {
            return embedding
        } else {
            print("Failed to deserialize embedding from JSON for rule: \(rule.id)")
            return nil
        }
    }
    
    // MARK: - Text Embedding Generation
    
    /// Generate vector embedding for text using NaturalLanguage framework (now uses sentence embedding)
    func generateTextEmbedding(for text: String) -> [Double]? {
        guard let embedding = nlEmbedding else {
            print("NLEmbedding not available.")
            return nil
        }
        
        let processedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure the text is not empty, as sentenceEmbedding might not handle it well.
        guard !processedText.isEmpty else {
            print("Cannot generate embedding for empty text.")
            return nil
        }
        
        // Get vector for the entire processed text (sentence or filename)
        guard let vector = embedding.vector(for: processedText) else {
            // This can happen if the text is too short, all stop words, or out-of-vocabulary for the model.
            print("Could not generate vector for text: \\(processedText)")
            return nil
        }
        
        // Normalize to unit length for consistent similarity calculations
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else {
            // Avoid division by zero if magnitude is zero (e.g., vector of all zeros)
            print("Vector magnitude is zero for text: \\(processedText)")
            return vector // Or return nil, depending on desired handling
        }
        
        return vector.map { $0 / magnitude }
    }
    
    /// Calculate cosine similarity between two vectors
    private func cosineSimilarity(_ vector1: [Double], _ vector2: [Double]) -> Double {
        guard vector1.count == vector2.count else { return 0 }
        
        let dotProduct = zip(vector1, vector2).map(*).reduce(0, +)
        let magnitude1 = sqrt(vector1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(vector2.map { $0 * $0 }.reduce(0, +))
        
        guard magnitude1 > 0 && magnitude2 > 0 else { return 0 }
        
        return dotProduct / (magnitude1 * magnitude2)
    }
}

// MARK: - Convenience Extensions

extension DatabaseService {
    var inputFolder: String {
        return getSettings().inputFolder
    }
    
    var outputFolder: String {
        return getSettings().outputFolder
    }

    var isFileMonitoringActive: Bool {
        return getSettings().isFileMonitoringActive
    }
    
    func setInputFolder(_ path: String) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: path, outputFolder: currentSettings.outputFolder, isFileMonitoringActive: currentSettings.isFileMonitoringActive)
    }
    
    func setOutputFolder(_ path: String) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: currentSettings.inputFolder, outputFolder: path, isFileMonitoringActive: currentSettings.isFileMonitoringActive)
    }

    func setIsFileMonitoringActive(_ isActive: Bool) {
        let currentSettings = getSettings()
        updateSettings(inputFolder: currentSettings.inputFolder, outputFolder: currentSettings.outputFolder, isFileMonitoringActive: isActive)
    }
} 
