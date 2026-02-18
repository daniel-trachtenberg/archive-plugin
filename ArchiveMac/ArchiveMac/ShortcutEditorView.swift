import SwiftUI

struct ShortcutEditorRow: View {
    let title: String
    let subtitle: String
    @Binding var shortcut: ShortcutDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(shortcut.displayString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Picker("Key", selection: keyBinding) {
                    ForEach(ShortcutKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)

                HStack(spacing: 6) {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        modifierButton(for: modifier)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var keyBinding: Binding<ShortcutKey> {
        Binding(
            get: { shortcut.key },
            set: { newKey in
                var updated = shortcut
                updated.key = newKey
                shortcut = updated
            }
        )
    }

    private func modifierButton(for modifier: ShortcutModifier) -> some View {
        let isSelected = shortcut.modifiers.contains(modifier)

        return Button {
            toggleModifier(modifier)
        } label: {
            Text(modifier.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(modifierHelpText(for: modifier))
    }

    private func toggleModifier(_ modifier: ShortcutModifier) {
        var updated = shortcut

        if let index = updated.modifiers.firstIndex(of: modifier) {
            if updated.modifiers.count == 1 {
                return
            }
            updated.modifiers.remove(at: index)
        } else {
            updated.modifiers.append(modifier)
        }

        updated.normalize()
        shortcut = updated
    }

    private func modifierHelpText(for modifier: ShortcutModifier) -> String {
        switch modifier {
        case .command:
            return "Command"
        case .option:
            return "Option"
        case .control:
            return "Control"
        case .shift:
            return "Shift"
        }
    }
}
