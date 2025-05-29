import Foundation
import NaturalLanguage

/*
 * VectorMatchingService.swift
 * 
 * Handles vector-based content matching for the Smart File Organizer using semantic embeddings.
 * Provides high-quality content-aware file organization by comparing file content against rule descriptions.
 */

// MARK: - Enhanced Match Result

struct ContentMatchResult {
    let rule: OrganizationRule
    let similarity: Double
    let explanation: String
}

// MARK: - Vector Matching Service

class VectorMatchingService {
    static let shared = VectorMatchingService()
    
    private let database = DatabaseService.shared
    
    private init() {}
    
    /// Find the best matching rule for extracted file content
    func findBestMatch(for content: ExtractedContent) -> ContentMatchResult? {
        // Use the new two-step matching logic from DatabaseService
        guard let vectorMatch = database.findBestMatchingRule(forFilename: content.fileName, contentText: content.extractedText) else {
            print("No matching rule found for: \(content.fileName) using either filename or content.")
            return nil
        }
        
        // Generate simplified explanation
        let explanation = generateExplanation(
            rule: vectorMatch.rule,
            similarity: vectorMatch.similarity,
            fileName: content.fileName
        )
        
        return ContentMatchResult(
            rule: vectorMatch.rule,
            similarity: vectorMatch.similarity,
            explanation: explanation
        )
    }
    
    // MARK: - Private Helper Methods
    
    /// Generate human-readable explanation for the match
    private func generateExplanation(rule: OrganizationRule, similarity: Double, fileName: String) -> String {
        let similarityPercent = Int(similarity * 100)
        
        return """
        Match found with \(similarityPercent)% similarity.
        Rule: "\(rule.name)"
        File: \(fileName)
        Destination: \(rule.destinationFolder)
        """
    }
} 