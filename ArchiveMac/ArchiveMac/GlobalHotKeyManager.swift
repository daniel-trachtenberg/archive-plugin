import AppKit
import Carbon

final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private static let eventSignature: OSType = {
        let signature = "ArHK"
        var value: OSType = 0
        for scalar in signature.utf16 {
            value = (value << 8) + OSType(scalar)
        }
        return value
    }()

    private var eventHandler: EventHandlerRef?
    private var registeredHotKeys: [ShortcutAction: EventHotKeyRef] = [:]

    var onHotKeyPressed: ((ShortcutAction) -> Void)?

    private init() {
        installEventHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func rebind(
        preferredShortcuts: [ShortcutAction: ShortcutDefinition],
        fallbackShortcuts: [ShortcutAction: [ShortcutDefinition]]
    ) -> [ShortcutAction: ShortcutDefinition] {
        installEventHandlerIfNeeded()
        unregisterAll()

        var resolvedShortcuts: [ShortcutAction: ShortcutDefinition] = [:]
        var reservedCombos = Set<String>()

        for action in ShortcutAction.allCases {
            guard let preferred = preferredShortcuts[action] else {
                continue
            }

            let candidateShortcuts = [preferred] + (fallbackShortcuts[action] ?? [])
            var seenCandidates = Set<String>()

            for candidate in candidateShortcuts {
                let comboID = comboIdentifier(for: candidate)

                if seenCandidates.contains(comboID) {
                    continue
                }
                seenCandidates.insert(comboID)

                if reservedCombos.contains(comboID) {
                    continue
                }

                guard let keyCode = carbonKeyCode(for: candidate.key) else {
                    print("[Hotkeys] Unsupported key for \(action.rawValue): \(candidate.key.rawValue)")
                    continue
                }

                let status = register(
                    action: action,
                    keyCode: keyCode,
                    modifiers: carbonModifiers(for: candidate.modifiers)
                )

                guard status == noErr else {
                    print("[Hotkeys] Registration failed for \(action.rawValue) \(candidate.displayString). OSStatus: \(status)")
                    continue
                }

                resolvedShortcuts[action] = candidate
                reservedCombos.insert(comboID)
                break
            }

            if resolvedShortcuts[action] == nil {
                print("[Hotkeys] No usable shortcut registered for \(action.rawValue)")
            }
        }

        return resolvedShortcuts
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            archiveHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandler
        )

        if status != noErr {
            print("[Hotkeys] Failed to install event handler. OSStatus: \(status)")
        }
    }

    private func register(action: ShortcutAction, keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        var eventHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.eventSignature, id: hotKeyID(for: action))

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &eventHotKey
        )

        if status == noErr, let eventHotKey {
            registeredHotKeys[action] = eventHotKey
        }

        return status
    }

    private func unregisterAll() {
        for hotKey in registeredHotKeys.values {
            UnregisterEventHotKey(hotKey)
        }
        registeredHotKeys.removeAll()
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        guard hotKeyID.signature == Self.eventSignature,
              let action = action(forHotKeyID: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        guard registeredHotKeys[action] != nil else {
            return OSStatus(eventNotHandledErr)
        }

        if let onHotKeyPressed {
            DispatchQueue.main.async {
                onHotKeyPressed(action)
            }
        }

        return noErr
    }

    private func action(forHotKeyID id: UInt32) -> ShortcutAction? {
        switch id {
        case 1:
            return .search
        case 2:
            return .upload
        case 3:
            return .settings
        default:
            return nil
        }
    }

    private func hotKeyID(for action: ShortcutAction) -> UInt32 {
        switch action {
        case .search:
            return 1
        case .upload:
            return 2
        case .settings:
            return 3
        }
    }

    private func comboIdentifier(for shortcut: ShortcutDefinition) -> String {
        let mods = shortcut.modifiers.map(\.rawValue).joined(separator: "+")
        return "\(mods)|\(shortcut.key.rawValue)"
    }

    private func carbonModifiers(for modifiers: [ShortcutModifier]) -> UInt32 {
        modifiers.reduce(UInt32(0)) { partialResult, modifier in
            switch modifier {
            case .command:
                return partialResult | UInt32(cmdKey)
            case .option:
                return partialResult | UInt32(optionKey)
            case .control:
                return partialResult | UInt32(controlKey)
            case .shift:
                return partialResult | UInt32(shiftKey)
            }
        }
    }

    private func carbonKeyCode(for key: ShortcutKey) -> UInt32? {
        switch key {
        case .space:
            return UInt32(kVK_Space)
        case .comma:
            return UInt32(kVK_ANSI_Comma)
        case .period:
            return UInt32(kVK_ANSI_Period)
        case .slash:
            return UInt32(kVK_ANSI_Slash)
        case .semicolon:
            return UInt32(kVK_ANSI_Semicolon)
        case .minus:
            return UInt32(kVK_ANSI_Minus)
        case .equal:
            return UInt32(kVK_ANSI_Equal)
        case .zero:
            return UInt32(kVK_ANSI_0)
        case .one:
            return UInt32(kVK_ANSI_1)
        case .two:
            return UInt32(kVK_ANSI_2)
        case .three:
            return UInt32(kVK_ANSI_3)
        case .four:
            return UInt32(kVK_ANSI_4)
        case .five:
            return UInt32(kVK_ANSI_5)
        case .six:
            return UInt32(kVK_ANSI_6)
        case .seven:
            return UInt32(kVK_ANSI_7)
        case .eight:
            return UInt32(kVK_ANSI_8)
        case .nine:
            return UInt32(kVK_ANSI_9)
        case .a:
            return UInt32(kVK_ANSI_A)
        case .b:
            return UInt32(kVK_ANSI_B)
        case .c:
            return UInt32(kVK_ANSI_C)
        case .d:
            return UInt32(kVK_ANSI_D)
        case .e:
            return UInt32(kVK_ANSI_E)
        case .f:
            return UInt32(kVK_ANSI_F)
        case .g:
            return UInt32(kVK_ANSI_G)
        case .h:
            return UInt32(kVK_ANSI_H)
        case .i:
            return UInt32(kVK_ANSI_I)
        case .j:
            return UInt32(kVK_ANSI_J)
        case .k:
            return UInt32(kVK_ANSI_K)
        case .l:
            return UInt32(kVK_ANSI_L)
        case .m:
            return UInt32(kVK_ANSI_M)
        case .n:
            return UInt32(kVK_ANSI_N)
        case .o:
            return UInt32(kVK_ANSI_O)
        case .p:
            return UInt32(kVK_ANSI_P)
        case .q:
            return UInt32(kVK_ANSI_Q)
        case .r:
            return UInt32(kVK_ANSI_R)
        case .s:
            return UInt32(kVK_ANSI_S)
        case .t:
            return UInt32(kVK_ANSI_T)
        case .u:
            return UInt32(kVK_ANSI_U)
        case .v:
            return UInt32(kVK_ANSI_V)
        case .w:
            return UInt32(kVK_ANSI_W)
        case .x:
            return UInt32(kVK_ANSI_X)
        case .y:
            return UInt32(kVK_ANSI_Y)
        case .z:
            return UInt32(kVK_ANSI_Z)
        }
    }
}

private func archiveHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleHotKeyEvent(event)
}
