import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let settings = SettingsStore.shared
    private lazy var captureCoordinator = CaptureCoordinator(settings: settings)
    private var settingsController: SettingsWindowController?
    private var welcomeController: WelcomeWindowController?
    private var shortcutWarningItem: NSMenuItem?
    private var hotKeyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
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
        menu.addItem(menuItem(
            "取消当前截图",
            action: #selector(cancelCurrentCapture),
            shortcut: ".",
            modifiers: [.command]
        ))
        menu.addItem(menuItem("关闭全部贴图", action: #selector(closeAllPinnedImages)))
        menu.addItem(.separator())
        menu.addItem(menuItem("打开最近截图", action: #selector(openRecent)))
        menu.addItem(menuItem("设置…", action: #selector(openSettings), shortcut: "0"))
        let warning = menuItem("快捷键未就绪 · 查看设置…", action: #selector(openSettings))
        warning.isHidden = true
        shortcutWarningItem = warning
        menu.addItem(warning)
        menu.addItem(menuItem("操作说明", action: #selector(showHelp)))
        menu.addItem(menuItem("关于 LocalShot", action: #selector(showAbout)))
        menu.addItem(menuItem("隐私说明", action: #selector(showPrivacy)))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "退出 LocalShot",
            action: #selector(quit),
            shortcut: "q",
            modifiers: [.command]
        ))
        statusItem.menu = menu
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "LocalShot", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("关于 LocalShot", action: #selector(showAbout)))
        appMenu.addItem(menuItem("设置…", action: #selector(openSettings), shortcut: ",", modifiers: [.command]))
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 LocalShot",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        for (title, action, key) in [
            ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
            ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(menuItem("LocalShot 操作说明", action: #selector(showHelp)))
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        shortcut: String = "",
        modifiers: NSEvent.ModifierFlags = [.command, .shift]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.target = self
        if !shortcut.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private func configureHotKeys() {
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: HotKeyManager.registrationDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHotKeyStatus() }
        }
        HotKeyManager.shared.onAction = { [weak self] action in
            Task { @MainActor in
                guard let self else { return }
                switch action {
                case .region: self.startCapture(.region)
                case .fullScreen: self.startCapture(.fullScreen)
                case .settings:
                    self.captureCoordinator.cancelPendingCapture()
                    self.openSettings()
                case .emergencyCancel:
                    self.captureCoordinator.cancelActiveCapture()
                }
            }
        }
        HotKeyManager.shared.register(settings: settings)
    }

    private func refreshHotKeyStatus() {
        let issues = HotKeyManager.shared.registrationIssues
        shortcutWarningItem?.isHidden = issues.isEmpty
        statusItem.button?.toolTip = issues.isEmpty
            ? "\(AppBuildInfo.display) — 本地隐私截屏"
            : "LocalShot：\(issues.map { $0.action.title }.joined(separator: "、"))快捷键未就绪，请打开设置"
    }

    private func startCapture(_ mode: CaptureMode) {
        Task { await captureCoordinator.start(mode) }
    }

    @objc private func captureRegion() { startCapture(.region) }
    @objc private func captureFullScreen() { startCapture(.fullScreen) }
    @objc private func cancelCurrentCapture() { captureCoordinator.cancelActiveCapture() }
    @objc private func closeAllPinnedImages() { captureCoordinator.closePinnedImages() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeAllPinnedImages) {
            return captureCoordinator.pinnedImageCount > 0
        }
        if menuItem.action == #selector(openRecent) { return settings.lastSavedURL != nil }
        return true
    }

    @objc private func openRecent() {
        guard let url = settings.lastSavedURL else {
            showAlert(title: "还没有最近截图", message: "保存第一张截图后，可从这里快速打开。")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        self.captureCoordinator.cancelPendingCapture()
        if settingsController?.window == nil {
            settingsController = nil
        }
        if settingsController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onQuit = { [weak self] in self?.quit() }
            settingsController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPrivacy() {
        showAlert(
            title: "LocalShot 隐私承诺",
            message: "截图与标注完全在本机完成。应用不包含网络功能，不收集分析数据，不主动读取剪贴板内容，也不申请辅助功能、输入监控、麦克风或摄像头权限。只有你操作复制、粘贴或保存时才会执行相应动作。"
        )
    }

    @objc private func showHelp() {
        openSettings()
        settingsController?.selectHelpTab()
    }

    @objc private func showAbout() {
        showAlert(
            title: AppBuildInfo.display,
            message: "本地截图与标注工具。\n\n当前版本以设置中显示的运行位置为准。安装更新后，请退出旧进程，再重新打开 App。\n\n完全本地运行，不包含网络功能或截图历史库。"
        )
    }

    @objc private func quit() {
        captureCoordinator.cancelActiveCapture()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        captureCoordinator.cancelActiveCapture()
        return .terminateNow
    }

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
