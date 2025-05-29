import Foundation

struct SearchResult: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let path: String
    let type: FileType
    
    enum FileType: String {
        case document
        case image
        case spreadsheet
        case text
        case other
        
        var icon: String {
            switch self {
            case .document: return "doc.text"
            case .image: return "photo"
            case .spreadsheet: return "tablecells"
            case .text: return "text.alignleft"
            case .other: return "file"
            }
        }
    }
}
