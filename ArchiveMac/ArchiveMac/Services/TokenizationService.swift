import Foundation

/*
 * TokenizationService.swift
 * 
 * Handles tokenization of filenames and content into individual words for word embedding matching.
 * Provides specialized tokenization for different input types.
 */

class TokenizationService {
    static let shared = TokenizationService()
    
    private init() {}
    
    /// Tokenize filename into individual words
    /// Handles common filename patterns: spaces, hyphens, underscores, camelCase, numbers
    func tokenizeFilename(_ filename: String) -> [String] {
        print("🔤 Tokenizing filename: '\(filename)'")
        
        // Remove file extension first
        let nameWithoutExtension = (filename as NSString).deletingPathExtension
        
        var tokens: [String] = []
        
        // Step 1: Split by common delimiters (spaces, hyphens, underscores, dots)
        let delimiters = CharacterSet(charactersIn: " -_.()[]{}!@#$%^&*+=|\\:;\"'<>,?/~`")
        let initialSplit = nameWithoutExtension.components(separatedBy: delimiters)
        
        // Step 2: Further split each piece by camelCase/PascalCase and numbers
        for piece in initialSplit {
            guard !piece.isEmpty else { continue }
            tokens.append(contentsOf: splitCamelCaseAndNumbers(piece))
        }
        
        // Step 3: Clean and filter tokens
        let cleanTokens = tokens
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && $0.count > 1 } // Remove single characters
        
        print("📝 Filename tokens: \(cleanTokens)")
        return cleanTokens
    }
    
    /// Tokenize content text into individual words
    /// Simple space-based splitting with cleanup
    func tokenizeContent(_ content: String) -> [String] {
        print("🔤 Tokenizing content (length: \(content.count) characters)")
        
        // Split by whitespace and punctuation
        let tokens = content.lowercased()
            .components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty && $0.count > 2 } // Remove short words
        
        // Remove duplicates while preserving order and limit to reasonable size
        let uniqueTokens = Array(NSOrderedSet(array: tokens)) as! [String]
        let limitedTokens = Array(uniqueTokens.prefix(500)) // Limit to first 500 unique words
        
        print("📝 Content tokens: \(limitedTokens.count) unique words")
        return limitedTokens
    }
    
    /// Split camelCase/PascalCase words and separate numbers
    private func splitCamelCaseAndNumbers(_ input: String) -> [String] {
        var result: [String] = []
        var currentWord = ""
        
        for (index, char) in input.enumerated() {
            let isUpperCase = char.isUppercase
            let isNumber = char.isNumber
            let isLastChar = index == input.count - 1
            
            // Start new word on uppercase letter (except first character)
            if isUpperCase && index > 0 && !currentWord.isEmpty {
                result.append(currentWord)
                currentWord = String(char)
            }
            // Start new word on number transition
            else if isNumber && !currentWord.isEmpty && !currentWord.last!.isNumber {
                result.append(currentWord)
                currentWord = String(char)
            }
            // Start new word when transitioning from number to letter
            else if !isNumber && !currentWord.isEmpty && currentWord.last!.isNumber {
                result.append(currentWord)
                currentWord = String(char)
            }
            else {
                currentWord.append(char)
            }
            
            // Add the last word
            if isLastChar && !currentWord.isEmpty {
                result.append(currentWord)
            }
        }
        
        return result.filter { !$0.isEmpty }
    }
}

// MARK: - String Extensions for Character Checking

extension Character {
    var isNumber: Bool {
        return self.isASCII && self.asciiValue! >= 48 && self.asciiValue! <= 57
    }
} 