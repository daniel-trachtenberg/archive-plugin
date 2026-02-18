import SwiftUI
import AppKit
import HotKey

enum ShortcutAction: String, CaseIterable, Identifiable {
    case search
    case upload
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:
            return "Search"
        case .upload:
            return "Upload"
        case .settings:
            return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .search:
            return "Open search window"
        case .upload:
            return "Open upload window"
        case .settings:
            return "Open settings"
        }
    }

    var defaultShortcut: ShortcutDefinition {
        switch self {
        case .search:
            return ShortcutDefinition(key: .space, modifiers: [.option])
        case .upload:
            return ShortcutDefinition(key: .u, modifiers: [.option])
        case .settings:
            return ShortcutDefinition(key: .comma, modifiers: [.command])
        }
    }
}

enum ShortcutModifier: String, CaseIterable, Codable, Identifiable {
    case command
    case option
    case control
    case shift

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .command:
            return "⌘"
        case .option:
            return "⌥"
        case .control:
            return "⌃"
        case .shift:
            return "⇧"
        }
    }

    var sortOrder: Int {
        switch self {
        case .control:
            return 0
        case .option:
            return 1
        case .shift:
            return 2
        case .command:
            return 3
        }
    }

    var keyboardModifier: EventModifiers {
        switch self {
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        case .shift:
            return .shift
        }
    }

    var hotKeyModifier: NSEvent.ModifierFlags {
        switch self {
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        case .shift:
            return .shift
        }
    }
}

enum ShortcutKey: String, CaseIterable, Codable, Identifiable {
    case space = "space"
    case comma = ","
    case period = "."
    case slash = "/"
    case semicolon = ";"
    case minus = "-"
    case equal = "="

    case zero = "0"
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"
    case five = "5"
    case six = "6"
    case seven = "7"
    case eight = "8"
    case nine = "9"

    case a = "a"
    case b = "b"
    case c = "c"
    case d = "d"
    case e = "e"
    case f = "f"
    case g = "g"
    case h = "h"
    case i = "i"
    case j = "j"
    case k = "k"
    case l = "l"
    case m = "m"
    case n = "n"
    case o = "o"
    case p = "p"
    case q = "q"
    case r = "r"
    case s = "s"
    case t = "t"
    case u = "u"
    case v = "v"
    case w = "w"
    case x = "x"
    case y = "y"
    case z = "z"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .space:
            return "Space"
        case .comma:
            return "Comma"
        case .period:
            return "Period"
        case .slash:
            return "Slash"
        case .semicolon:
            return "Semicolon"
        case .minus:
            return "Minus"
        case .equal:
            return "Equals"
        default:
            return rawValue.uppercased()
        }
    }

    var displayValue: String {
        switch self {
        case .space:
            return "Space"
        default:
            return rawValue.uppercased()
        }
    }

    var keyEquivalent: KeyEquivalent {
        if self == .space {
            return .space
        }
        return KeyEquivalent(Character(rawValue))
    }

    var hotKey: Key? {
        Key(string: rawValue)
    }
}

struct ShortcutDefinition: Codable, Equatable {
    var key: ShortcutKey
    var modifiers: [ShortcutModifier]

    init(key: ShortcutKey, modifiers: [ShortcutModifier]) {
        self.key = key
        self.modifiers = ShortcutDefinition.normalizedModifiers(modifiers)
    }

    mutating func normalize() {
        modifiers = ShortcutDefinition.normalizedModifiers(modifiers)
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(
            key.keyEquivalent,
            modifiers: modifiers.reduce(EventModifiers()) { partialResult, modifier in
                partialResult.union(modifier.keyboardModifier)
            }
        )
    }

    var displayString: String {
        let modifierSymbols = modifiers.map(\.symbol).joined()
        return "\(modifierSymbols)\(key.displayValue)"
    }

    func makeHotKey() -> HotKey? {
        guard let hotKey = key.hotKey else {
            return nil
        }

        let flags = modifiers.reduce(NSEvent.ModifierFlags()) { partialResult, modifier in
            partialResult.union(modifier.hotKeyModifier)
        }

        return HotKey(key: hotKey, modifiers: flags)
    }

    static func normalizedModifiers(_ values: [ShortcutModifier]) -> [ShortcutModifier] {
        let sorted = Array(Set(values)).sorted { lhs, rhs in
            lhs.sortOrder < rhs.sortOrder
        }

        if sorted.isEmpty {
            return [.option]
        }

        return sorted
    }
}

extension Notification.Name {
    static let archiveShortcutsDidChange = Notification.Name("archive.shortcutsDidChange")
}
