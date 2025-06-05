import Foundation
import PDFKit
import Vision
import AppKit
import UniformTypeIdentifiers

/*
 * ContentExtractionService.swift
 * 
 * This service handles content extraction from various file types for the Smart File Organizer.
 * It provides unified text extraction from PDFs, documents, images, and other supported formats.
 * 
 * Features:
 * - PDF text extraction using PDFKit
 * - Image OCR using Vision framework
 * - Document text extraction for various formats
 * - Content preprocessing and normalization
 * - Memory-efficient processing for large files
 */

// MARK: - Extracted Content Model

struct ExtractedContent {
    let fileURL: URL
    let fileName: String
    let fileType: String
    let extractedText: String
    let metadata: [String: Any]
    let extractionDate: Date
    let contentLength: Int
    
    init(fileURL: URL, extractedText: String, metadata: [String: Any] = [:]) {
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.fileType = fileURL.pathExtension.lowercased()
        self.extractedText = extractedText
        self.metadata = metadata
        self.extractionDate = Date()
        self.contentLength = extractedText.count
    }
}

// MARK: - Extraction Errors

enum ContentExtractionError: Error {
    case fileNotFound
    case unsupportedFileType
    case extractionFailed(String)
    case permissionDenied
    case fileTooLarge
    case corruptedFile
    
    var localizedDescription: String {
        switch self {
        case .fileNotFound:
            return "File not found"
        case .unsupportedFileType:
            return "Unsupported file type"
        case .extractionFailed(let reason):
            return "Extraction failed: \(reason)"
        case .permissionDenied:
            return "Permission denied to access file"
        case .fileTooLarge:
            return "File too large to process"
        case .corruptedFile:
            return "File appears to be corrupted"
        }
    }
}

// MARK: - Content Extraction Service

class ContentExtractionService {
    static let shared = ContentExtractionService()
    
    // MARK: - Configuration
    private let maxFileSize: Int = 50 * 1024 * 1024 // 50MB limit
    private let maxTextLength: Int = 10_000 // Limit extracted text to 10k characters
    
    // Supported file types
    private let supportedTypes: [String: ExtractionMethod] = [
        "pdf": .pdf,
        "txt": .plainText,
        "rtf": .richText,
        "md": .plainText,
        "doc": .document,
        "docx": .document,
        "jpg": .image,
        "jpeg": .image,
        "png": .image,
        "gif": .image,
        "heic": .image,
        "webp": .image,
        "tiff": .image,
        "bmp": .image
    ]
    
    private enum ExtractionMethod {
        case pdf
        case plainText
        case richText
        case document
        case image
    }
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Extract content from a file asynchronously
    func extractContent(from fileURL: URL) async throws -> ExtractedContent {
        print("📄 ContentExtractionService: Starting extraction for \(fileURL.lastPathComponent)")
        
        // Verify file exists and is accessible
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ File not found: \(fileURL.path)")
            throw ContentExtractionError.fileNotFound
        }
        
        // Check file size
        let fileSize = try getFileSize(fileURL)
        print("📏 File size: \(fileSize) bytes")
        guard fileSize <= maxFileSize else {
            print("❌ File too large: \(fileSize) bytes (max: \(maxFileSize))")
            throw ContentExtractionError.fileTooLarge
        }
        
        // Determine extraction method
        let fileExtension = fileURL.pathExtension.lowercased()
        print("📎 File extension: \(fileExtension)")
        guard let extractionMethod = supportedTypes[fileExtension] else {
            print("❌ Unsupported file type: \(fileExtension)")
            throw ContentExtractionError.unsupportedFileType
        }
        
        print("🔧 Using extraction method: \(extractionMethod)")
        
        // Extract content based on file type
        let extractedText: String
        var metadata: [String: Any] = [:]
        
        switch extractionMethod {
        case .pdf:
            (extractedText, metadata) = try await extractFromPDF(fileURL)
        case .plainText:
            extractedText = try await extractFromPlainText(fileURL)
        case .richText:
            extractedText = try await extractFromRichText(fileURL)
        case .document:
            extractedText = try await extractFromDocument(fileURL)
        case .image:
            extractedText = try await extractFromImage(fileURL)
        }
        
        // Preprocess and normalize the extracted text
        let processedText = preprocessText(extractedText)
        
        print("✅ Extraction completed. Original length: \(extractedText.count), Processed length: \(processedText.count)")
        
        return ExtractedContent(
            fileURL: fileURL,
            extractedText: processedText,
            metadata: metadata
        )
    }
    
    // MARK: - PDF Extraction
    
    private func extractFromPDF(_ fileURL: URL) async throws -> (String, [String: Any]) {
        guard let pdfDocument = PDFDocument(url: fileURL) else {
            throw ContentExtractionError.extractionFailed("Could not open PDF document")
        }
        
        var extractedText = ""
        var metadata: [String: Any] = [:]
        
        // Extract metadata
        if let title = pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            metadata["title"] = title
        }
        if let author = pdfDocument.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
            metadata["author"] = author
        }
        if let subject = pdfDocument.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String {
            metadata["subject"] = subject
        }
        
        metadata["pageCount"] = pdfDocument.pageCount
        
        // Extract text from all pages
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            if let pageText = page.string {
                extractedText += pageText + "\n"
            }
            
            // Limit text length to prevent memory issues
            if extractedText.count > maxTextLength {
                extractedText = String(extractedText.prefix(maxTextLength))
                break
            }
        }
        
        return (extractedText, metadata)
    }
    
    // MARK: - Plain Text Extraction
    
    private func extractFromPlainText(_ fileURL: URL) async throws -> String {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return String(content.prefix(maxTextLength))
        } catch {
            // Try other encodings if UTF-8 fails
            do {
                let content = try String(contentsOf: fileURL, encoding: .ascii)
                return String(content.prefix(maxTextLength))
            } catch {
                throw ContentExtractionError.extractionFailed("Could not decode text file")
            }
        }
    }
    
    // MARK: - Rich Text Extraction
    
    private func extractFromRichText(_ fileURL: URL) async throws -> String {
        do {
            let attributedString = try NSAttributedString(
                url: fileURL,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            let plainText = attributedString.string
            return String(plainText.prefix(maxTextLength))
        } catch {
            throw ContentExtractionError.extractionFailed("Could not extract RTF content")
        }
    }
    
    // MARK: - Document Extraction (DOC/DOCX)
    
    private func extractFromDocument(_ fileURL: URL) async throws -> String {
        // For DOC/DOCX files, we'll try to use NSAttributedString
        // This provides basic text extraction for many document formats
        do {
            let attributedString = try NSAttributedString(
                url: fileURL,
                options: [:],
                documentAttributes: nil
            )
            let plainText = attributedString.string
            return String(plainText.prefix(maxTextLength))
        } catch {
            throw ContentExtractionError.extractionFailed("Could not extract document content")
        }
    }
    
    // MARK: - Image OCR Extraction
    
    private func extractFromImage(_ fileURL: URL) async throws -> String {
        guard let image = NSImage(contentsOf: fileURL) else {
            throw ContentExtractionError.extractionFailed("Could not load image")
        }
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ContentExtractionError.extractionFailed("Could not convert image format")
        }
        
        return try await performOCR(on: cgImage)
    }
    
    private func performOCR(on cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: ContentExtractionError.extractionFailed("OCR failed: \(error.localizedDescription)"))
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                let recognizedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                
                let limitedText = String(recognizedText.prefix(self.maxTextLength))
                continuation.resume(returning: limitedText)
            }
            
            // Configure OCR for better accuracy
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: ContentExtractionError.extractionFailed("OCR processing failed: \(error.localizedDescription)"))
            }
        }
    }
    
    // MARK: - Text Preprocessing
    
    private func preprocessText(_ text: String) -> String {
        var processedText = text
        
        // Remove excessive whitespace
        processedText = processedText.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        
        // Remove control characters
        processedText = processedText.components(separatedBy: .controlCharacters).joined()
        
        // Trim whitespace
        processedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure we don't exceed maximum length
        if processedText.count > maxTextLength {
            processedText = String(processedText.prefix(maxTextLength))
        }
        
        return processedText
    }
    
    // MARK: - Helper Methods
    
    private func getFileSize(_ fileURL: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes[.size] as? Int ?? 0
    }
    
    /// Check if a file type is supported for content extraction
    func isFileTypeSupported(_ fileURL: URL) -> Bool {
        let fileExtension = fileURL.pathExtension.lowercased()
        return supportedTypes.keys.contains(fileExtension)
    }
    
    /// Get supported file extensions
    func getSupportedExtensions() -> [String] {
        return Array(supportedTypes.keys)
    }
} 