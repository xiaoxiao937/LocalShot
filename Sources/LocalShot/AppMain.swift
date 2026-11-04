import AppKit
import Darwin

@main
@MainActor
struct LocalShotMain {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--smoke-test-settings") {
            application.setActivationPolicy(.prohibited)
            let first = SettingsWindowController(settings: .shared)
            guard let firstWindow = first.window else { exit(2) }
            firstWindow.contentView?.layoutSubtreeIfNeeded()
            first.close()
            guard first.window != nil else { exit(3) }

            let second = SettingsWindowController(settings: .shared)
            guard let secondWindow = second.window else { exit(4) }
            secondWindow.contentView?.layoutSubtreeIfNeeded()
            second.close()
            print("设置窗口生命周期审计通过")
            return
        }
        // Multiple downloaded copies share one identity and one shortcut set.
        // Reopening an existing instance brings its settings forward instead
        // of creating another competing capture process.
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.localshot.app")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if let url = existing.bundleURL { NSWorkspace.shared.open(url) }
            existing.activate(options: [])
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
