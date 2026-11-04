import AppKit
import Carbon

enum HotKeyAction: UInt32 {
    case region = 1
    case fullScreen = 3
    case settings = 10
    case emergencyCancel = 11

    var title: String {
        switch self {
        case .region: return "区域截图"
        case .fullScreen: return "全屏截图"
        case .settings: return "打开设置"
        case .emergencyCancel: return "紧急取消"
        }
    }
}

struct HotKeyRegistrationIssue {
    let action: HotKeyAction
    let status: OSStatus
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    static let registrationDidChange = Notification.Name("LocalShotHotKeyRegistrationDidChange")
    var onAction: ((HotKeyAction) -> Void)?
    private(set) var registrationIssues: [HotKeyRegistrationIssue] = []

    private var refs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var eventHandlerStatus: OSStatus = noErr

    private init() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        eventHandlerStatus = InstallEventHandler(
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
        registrationIssues.removeAll()
        guard eventHandlerStatus == noErr else {
            registrationIssues = [HotKeyAction.region, .fullScreen, .settings, .emergencyCancel].map {
                HotKeyRegistrationIssue(action: $0, status: eventHandlerStatus)
            }
            NotificationCenter.default.post(name: Self.registrationDidChange, object: self)
            return
        }
        register(action: .region, keyCode: UInt32(settings.regionKeyCode))
        register(action: .fullScreen, keyCode: UInt32(settings.fullScreenKeyCode))
        // Fixed recovery shortcut. It remains available even when the user
        // hides the menu-bar item and the app has no Dock icon.
        register(action: .settings, keyCode: 29)
        // A second, dedicated escape hatch that never starts another action.
        // Command-Shift-Escape avoids the system Command-Option-Escape chord.
        register(action: .emergencyCancel, keyCode: 53)
        NotificationCenter.default.post(name: Self.registrationDidChange, object: self)
    }

    private func register(action: HotKeyAction, keyCode: UInt32) {
        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: fourCC("LSHT"), id: action.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            registrationIssues.append(HotKeyRegistrationIssue(action: action, status: status))
            NSLog("LocalShot failed to register hotkey %u (status %d)", action.rawValue, status)
            return
        }
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
