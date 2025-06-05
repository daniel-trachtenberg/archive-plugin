import Foundation
import NaturalLanguage

/*
 * VectorMatchingService.swift
 * 
 * Handles all word-based content matching for the Smart File Organizer using keyword embeddings.
 * Provides high-quality content-aware file organization by comparing file content tokens against rule keywords.
 */

// MARK: - Enhanced Match Result

struct ContentMatchResult {
    let rule: OrganizationRule
    let similarity: Double
    let explanation: String
    let matchedKeywords: [String]
    let matchSource: String // "filename" or "content"
}

// MARK: - Vector Matching Service

class VectorMatchingService {
    static let shared = VectorMatchingService()
    
    private let database = DatabaseService.shared
    private let tokenizer = TokenizationService.shared
    private let nlEmbedding = NLEmbedding.wordEmbedding(for: .english)
    
    private init() {}
    
    /// Main entry point: Find the best matching rule for extracted file content
    func findBestMatch(for content: ExtractedContent) -> ContentMatchResult? {
        print("🧠 VectorMatchingService: Starting keyword match for file: \(content.fileName)")
        print("📄 Content length: \(content.contentLength) characters")
        
        // Get active rules
        let allRules = database.getAllRules()
        let activeRules = allRules.filter { $0.isActive }
        
        print("📋 Total rules in database: \(allRules.count)")
        print("✅ Active rules: \(activeRules.count)")
        
        guard !activeRules.isEmpty else {
            print("❌ No active rules found! File cannot be organized.")
            return nil
        }
        
        // Log the active rules and their keywords
        for rule in activeRules {
            if rule.keywords.isEmpty {
                print("⚠️ Rule '\(rule.name)' has no keywords defined")
            } else {
                print("📝 Active rule: '\(rule.name)' keywords: \(rule.keywords) -> \(rule.destinationFolder)")
            }
        }
        
        // Two-stage matching: filename first, then content
        return findBestMatchingRule(forFilename: content.fileName, contentText: content.extractedText, rules: activeRules)
    }
    
    /// Two-stage keyword matching: filename first, then content
    private func findBestMatchingRule(forFilename filename: String, contentText: String, rules: [OrganizationRule]) -> ContentMatchResult? {
        print("🔍 VectorMatchingService: Finding match for filename: '\(filename)'")
        
        // Stage 1: Try to match against filename tokens
        print("1️⃣ Attempting filename-based keyword matching...")
        let filenameTokens = tokenizer.tokenizeFilename(filename)
        
        if let filenameMatch = findBestKeywordMatch(rules: rules, documentTokens: filenameTokens, source: "filename") {
            return filenameMatch
        }
        
        // Stage 2: If no filename match, try content tokens
        print("2️⃣ Attempting content-based keyword matching...")
        let contentTokens = tokenizer.tokenizeContent(contentText)
        
        if let contentMatch = findBestKeywordMatch(rules: rules, documentTokens: contentTokens, source: "content") {
            return contentMatch
        }
        
        print("❌ No matches found above threshold (70%) in either filename or content")
        return nil
    }
    
    /// Find the best keyword match using pooled average similarity
    private func findBestKeywordMatch(rules: [OrganizationRule], documentTokens: [String], source: String) -> ContentMatchResult? {
        guard !documentTokens.isEmpty else {
            print("❌ No tokens to match against in \(source)")
            return nil
        }
        
        print("🔍 Evaluating \(source) tokens: \(documentTokens.prefix(10))...")
        
        // Generate embeddings for document tokens
        let documentEmbeddings = documentTokens.compactMap { token in
            generateWordEmbedding(for: token)
        }
        
        guard !documentEmbeddings.isEmpty else {
            print("❌ Could not generate embeddings for any \(source) tokens")
            return nil
        }
        
        var bestMatch: ContentMatchResult? = nil
        let threshold = 0.70
        
        // Check each rule
        for rule in rules {
            guard !rule.keywords.isEmpty else {
                print("⚠️ Rule '\(rule.name)' has no keywords")
                continue
            }
            
            print("📊 Checking rule '\(rule.name)' with keywords: \(rule.keywords)")
            
            // Generate embeddings for rule keywords
            let keywordEmbeddings = rule.keywords.compactMap { keyword in
                generateWordEmbedding(for: keyword.lowercased())
            }
            
            guard !keywordEmbeddings.isEmpty else {
                print("⚠️ Could not generate embeddings for rule '\(rule.name)' keywords")
                continue
            }
            
            // Calculate pooled average similarity
            let (averageSimilarity, matchedKeywords) = calculatePooledAverageSimilarity(
                keywordEmbeddings: keywordEmbeddings,
                keywords: rule.keywords,
                documentEmbeddings: documentEmbeddings,
                documentTokens: documentTokens
            )
            
            print("📊 Rule '\(rule.name)' pooled average similarity: \(Int(averageSimilarity * 100))% (matched keywords: \(matchedKeywords.joined(separator: ", ")))")
            
            // Check if this rule meets the threshold and is better than current best
            if averageSimilarity >= threshold {
                if bestMatch == nil || averageSimilarity > bestMatch!.similarity {
                    let explanation = generateExplanation(
                        rule: rule,
                        similarity: averageSimilarity,
                        matchedKeywords: matchedKeywords,
                        source: source
                    )
                    
                    bestMatch = ContentMatchResult(
                        rule: rule,
                        similarity: averageSimilarity,
                        explanation: explanation,
                        matchedKeywords: matchedKeywords,
                        matchSource: source
                    )
                    print("🎯 New best match above threshold: '\(rule.name)' with \(Int(averageSimilarity * 100))%")
                }
            }
        }
        
        if let bestMatch = bestMatch {
            print("✅ Best \(source) match: '\(bestMatch.rule.name)' with \(Int(bestMatch.similarity * 100))%")
        } else {
            print("❌ No \(source) matches found above threshold (\(Int(threshold * 100))%)")
        }
        
        return bestMatch
    }
    
    /// Calculate pooled average similarity between rule keywords and document tokens
    private func calculatePooledAverageSimilarity(
        keywordEmbeddings: [[Double]],
        keywords: [String],
        documentEmbeddings: [[Double]],
        documentTokens: [String]
    ) -> (similarity: Double, matchedKeywords: [String]) {
        
        var totalSimilarity = 0.0
        var matchCount = 0
        var matchedKeywords: Set<String> = []
        
        // For each keyword, find its best match in the document tokens
        for (keywordIndex, keywordEmbedding) in keywordEmbeddings.enumerated() {
            var bestSimilarityForKeyword = 0.0
            var bestMatchToken = ""
            
            // Find the best matching document token for this keyword
            for (tokenIndex, documentEmbedding) in documentEmbeddings.enumerated() {
                let similarity = cosineSimilarity(keywordEmbedding, documentEmbedding)
                if similarity > bestSimilarityForKeyword {
                    bestSimilarityForKeyword = similarity
                    bestMatchToken = documentTokens[tokenIndex]
                }
            }
            
            // Only include matches above a minimum threshold (0.5) in the average
            if bestSimilarityForKeyword >= 0.5 {
                totalSimilarity += bestSimilarityForKeyword
                matchCount += 1
                matchedKeywords.insert(keywords[keywordIndex])
                print("   🔗 '\(keywords[keywordIndex])' matches '\(bestMatchToken)' with \(Int(bestSimilarityForKeyword * 100))%")
            }
        }
        
        // Calculate average similarity
        let averageSimilarity = matchCount > 0 ? totalSimilarity / Double(matchCount) : 0.0
        
        return (averageSimilarity, Array(matchedKeywords))
    }
    
    /// Generate word embedding for a single word using NaturalLanguage framework
    private func generateWordEmbedding(for word: String) -> [Double]? {
        guard let embedding = nlEmbedding else {
            print("NLEmbedding not available.")
            return nil
        }
        
        let processedWord = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !processedWord.isEmpty else {
            return nil
        }
        
        // Get word embedding
        guard let vector = embedding.vector(for: processedWord) else {
            return nil
        }
        
        // Normalize to unit length for consistent similarity calculations
        let magnitude = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else {
            return vector
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
    
    /// Generate human-readable explanation for the keyword match
    private func generateExplanation(rule: OrganizationRule, similarity: Double, matchedKeywords: [String], source: String) -> String {
        let similarityPercent = Int(similarity * 100)
        let keywordsString = matchedKeywords.joined(separator: ", ")
        
        return """
        \(source.capitalized) match found with \(similarityPercent)% average similarity.
        Rule: "\(rule.name)"
        Matched Keywords: [\(keywordsString)]
        Destination: \(rule.destinationFolder)
        """
    }
} 