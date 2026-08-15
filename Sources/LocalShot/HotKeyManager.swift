import AppKit
import Carbon

enum HotKeyAction: UInt32 {
    case region = 1
    case fullScreen = 3
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    var onAction: ((HotKeyAction) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?

    private init() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, let action = HotKeyAction(rawValue: hotKeyID.id) else { return status }
                Task { @MainActor in HotKeyManager.shared.onAction?(action) }
                return noErr
            },
            1,
            &type,
            nil,
            &eventHandler
        )
    }

    func register(settings: SettingsStore) {
        unregisterAll()
        register(action: .region, keyCode: UInt32(settings.regionKeyCode))
        register(action: .fullScreen, keyCode: UInt32(settings.fullScreenKeyCode))
    }

    private func register(action: HotKeyAction, keyCode: UInt32) {
        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: fourCC("LSHT"), id: action.rawValue)
        RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        refs.append(ref)
    }

    private func unregisterAll() {
        for ref in refs.compactMap({ $0 }) {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
    }

    private func fourCC(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
