import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey. Carbon's `RegisterEventHotKey` is used on purpose: unlike an
/// `NSEvent` global monitor it does not require the Accessibility permission.
final class GlobalHotkey {
    // Main-thread only: hotkeys are registered and released from `AppController`, and the Carbon
    // callback below hops to the main queue before it reaches the table.
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `UInt32(kVK_ANSI_R)`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | optionKey)`.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D48_4C50), id: id) // 'MHLP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        guard status == noErr else {
            Self.handlers[id] = nil
            Log.app.error("Cannot register hotkey: \(status, privacy: .public)")
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }

            let id = hotKeyID.id
            DispatchQueue.main.async {
                GlobalHotkey.handlers[id]?()
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
