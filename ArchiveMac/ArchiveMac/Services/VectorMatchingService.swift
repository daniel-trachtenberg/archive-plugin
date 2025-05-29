import Foundation
import NaturalLanguage

/*
 * VectorMatchingService.swift
 * 
 * This service handles vector-based content matching for the Smart File Organizer.
 * It uses text embeddings to compare extracted file content against organization rules
 * and provides high-quality semantic matching with confidence scores.
 * 
 * Features:
 * - Vector embeddings using NaturalLanguage framework
 * - Cosine similarity for semantic matching
 * - Intelligent content preprocessing
 * - Integration with DatabaseService for persistence
 */

// MARK: - Vector Match Result

struct VectorMatchResult {
    let rule: OrganizationRule
    let similarity: Double
    let confidence: Double
    let explanation: String
}

// MARK: - Vector Matching Service

class VectorMatchingService {
    static let shared = VectorMatchingService()
    
    private let database = DatabaseService.shared
    private let nlEmbedding = NLEmbedding.wordEmbedding(for: .english)
    
    private init() {}
    
    func findBestMatch(for content: ExtractedContent) -> VectorMatchResult? {
        guard let contentEmbedding = generateEmbedding(for: content.extractedText) else {
            return nil
        }
        
        guard let match = database.findBestMatchingRule(for: contentEmbedding) else {
            return nil
        }
        
        let confidence = calculateConfidence(similarity: match.similarity)
        let explanation = generateExplanation(rule: match.rule, similarity: match.similarity)
        
        return VectorMatchResult(
            rule: match.rule,
            similarity: match.similarity,
            confidence: confidence,
            explanation: explanation
        )
    }
    
    private func generateEmbedding(for text: String) -> [Double]? {
        guard let embedding = nlEmbedding else { return nil }
        
        let processedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = processedText
        
        var wordVectors: [[Double]] = []
        
        tokenizer.enumerateTokens(in: processedText.startIndex..<processedText.endIndex) { tokenRange, _ in
            let token = String(processedText[tokenRange])
            
            guard token.count > 2 && !token.allSatisfy({ $0.isPunctuation }) else {
                return true
            }
            
            if let vector = embedding.vector(for: token) {
                wordVectors.append(vector)
            }
            
            return true
        }
        
        guard !wordVectors.isEmpty else { return nil }
        
        // Calculate mean vector
        let vectorSize = wordVectors[0].count
        var meanVector = Array(repeating: 0.0, count: vectorSize)
        
        for vector in wordVectors {
            for i in 0..<vectorSize {
                meanVector[i] += vector[i]
            }
        }
        
        let count = Double(wordVectors.count)
        let normalizedVector = meanVector.map { $0 / count }
        
        // Normalize to unit length
        let magnitude = sqrt(normalizedVector.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return normalizedVector }
        
        return normalizedVector.map { $0 / magnitude }
    }
    
    private func calculateConfidence(similarity: Double) -> Double {
        // Simple confidence calculation based on similarity
        return min(similarity * 1.2, 1.0)
    }
    
    private func generateExplanation(rule: OrganizationRule, similarity: Double) -> String {
        let similarityPercent = Int(similarity * 100)
        return "Semantic similarity: \(similarityPercent)% match with rule '\(rule.name)'\nDestination: \(rule.destinationFolder)"
    }
} 