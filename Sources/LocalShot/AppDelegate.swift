import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = SettingsStore.shared
    private lazy var captureCoordinator = CaptureCoordinator(settings: settings)
    private var settingsController: SettingsWindowController?
    private var welcomeController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        configureHotKeys()
        if !showWelcomeIfNeeded() {
            openSettings()
        }
    }

    @discardableResult
    private func showWelcomeIfNeeded() -> Bool {
        guard !settings.hasShownWelcome else { return false }
        let controller = WelcomeWindowController()
        controller.onFinish = { [weak self] in
            self?.settings.hasShownWelcome = true
            self?.welcomeController = nil
        }
        welcomeController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "LocalShot")
            button.toolTip = "LocalShot — 本地隐私截屏"
        }

        let menu = NSMenu()
        menu.addItem(menuItem("截取区域", action: #selector(captureRegion)))
        menu.addItem(menuItem("截取全屏", action: #selector(captureFullScreen)))
        menu.addItem(.separator())
        menu.addItem(menuItem("打开最近截图", action: #selector(openRecent)))
        menu.addItem(menuItem("设置…", action: #selector(openSettings), shortcut: "0"))
        menu.addItem(menuItem("隐私说明", action: #selector(showPrivacy)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 LocalShot", action: #selector(quit), shortcut: "q"))
        statusItem.menu = menu
    }

    private func menuItem(_ title: String, action: Selector, shortcut: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.target = self
        if !shortcut.isEmpty { item.keyEquivalentModifierMask = [.command, .shift] }
        return item
    }

    private func configureHotKeys() {
        HotKeyManager.shared.onAction = { [weak self] action in
            Task { @MainActor in
                switch action {
                case .region: self?.startCapture(.region)
                case .fullScreen: self?.startCapture(.fullScreen)
                case .settings: self?.openSettings()
                }
            }
        }
        HotKeyManager.shared.register(settings: settings)
    }

    private func startCapture(_ mode: CaptureMode) {
        Task { await captureCoordinator.start(mode) }
    }

    @objc private func captureRegion() { startCapture(.region) }
    @objc private func captureFullScreen() { startCapture(.fullScreen) }

    @objc private func openRecent() {
        guard let url = settings.lastSavedURL else {
            showAlert(title: "还没有最近截图", message: "保存第一张截图后，可从这里快速打开。")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPrivacy() {
        showAlert(
            title: "LocalShot 隐私承诺",
            message: "截图与标注完全在本机完成。应用不包含网络功能，不收集分析数据，不读取剪贴板内容，也不申请辅助功能、输入监控、麦克风或摄像头权限。"
        )
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
