import AppKit

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let askSaveLocation = "askSaveLocation"
        static let includeCursor = "includeCursor"
        static let saveDirectoryBookmark = "saveDirectoryBookmark"
        static let lastSavedPath = "lastSavedPath"
        static let regionKeyCode = "regionKeyCode"
        static let fullScreenKeyCode = "fullScreenKeyCode"
        static let hasShownWelcome = "hasShownWelcome"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.askSaveLocation: true,
            Key.includeCursor: false,
            Key.regionKeyCode: 18,
            Key.fullScreenKeyCode: 20
        ])
    }

    var askSaveLocation: Bool {
        get { defaults.bool(forKey: Key.askSaveLocation) }
        set { defaults.set(newValue, forKey: Key.askSaveLocation) }
    }

    var includeCursor: Bool {
        get { defaults.bool(forKey: Key.includeCursor) }
        set { defaults.set(newValue, forKey: Key.includeCursor) }
    }

    var regionKeyCode: Int {
        get { defaults.integer(forKey: Key.regionKeyCode) }
        set { defaults.set(newValue, forKey: Key.regionKeyCode) }
    }

    var fullScreenKeyCode: Int {
        get { defaults.integer(forKey: Key.fullScreenKeyCode) }
        set { defaults.set(newValue, forKey: Key.fullScreenKeyCode) }
    }

    var hasShownWelcome: Bool {
        get { defaults.bool(forKey: Key.hasShownWelcome) }
        set { defaults.set(newValue, forKey: Key.hasShownWelcome) }
    }

    var lastSavedURL: URL? {
        guard let path = defaults.string(forKey: Key.lastSavedPath) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: path) ? url : nil
    }

    var saveDirectoryURL: URL? {
        guard let data = defaults.data(forKey: Key.saveDirectoryBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale { setSaveDirectory(url) }
        return url
    }

    func setSaveDirectory(_ url: URL) {
        let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: Key.saveDirectoryBookmark)
    }

    func recordSavedURL(_ url: URL) {
        defaults.set(url.path, forKey: Key.lastSavedPath)
    }

    func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "截图_\(formatter.string(from: date)).png"
    }
}

@MainActor
final class WelcomeWindowController: NSWindowController {
    var onFinish: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 LocalShot"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(icon)

        let title = NSTextField(labelWithString: "截屏，只留在你的 Mac 上")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(wrappingLabelWithString: "LocalShot 是一款完全本地运行的截屏与标注工具。只有当你主动截图时，它才会读取屏幕。")
        intro.font = .systemFont(ofSize: 15)
        stack.addArrangedSubview(intro)

        for text in [
            "✓ 不联网，不上传截图",
            "✓ 不收集分析、遥测或设备标识",
            "✓ 不申请辅助功能、输入监控、麦克风或摄像头",
            "✓ 默认不开机启动，截图后立即释放完整屏幕缓存"
        ] {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 14)
            stack.addArrangedSubview(label)
        }

        let permission = NSTextField(wrappingLabelWithString: "首次截图时，macOS 会询问“屏幕录制”权限。LocalShot 不会在此欢迎页申请权限。")
        permission.textColor = .secondaryLabelColor
        stack.addArrangedSubview(permission)

        let button = NSButton(title: "开始使用", target: self, action: #selector(finish))
        button.keyEquivalent = "\r"
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            intro.widthAnchor.constraint(equalToConstant: 488),
            permission.widthAnchor.constraint(equalToConstant: 488)
        ])
    }

    @objc private func finish() {
        onFinish?()
        close()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let folderLabel = NSTextField(labelWithString: "")
    private var shortcutPopups: [Int: NSPopUpButton] = [:]
    private let keyChoices: [(label: String, code: Int)] = [
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25)
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalShot 设置"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "通用")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        stack.addArrangedSubview(shortcutRow("区域截图", action: .region, keyCode: settings.regionKeyCode))
        stack.addArrangedSubview(shortcutRow("全屏截图", action: .fullScreen, keyCode: settings.fullScreenKeyCode))

        stack.addArrangedSubview(checkBox("保存时询问位置", state: settings.askSaveLocation, action: #selector(toggleAsk(_:))))
        stack.addArrangedSubview(checkBox("全屏截图包含鼠标指针", state: settings.includeCursor, action: #selector(toggleCursor(_:))))

        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.spacing = 10
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.toolTip = settings.saveDirectoryURL?.path
        let choose = NSButton(title: "选择保存目录…", target: self, action: #selector(chooseFolder))
        folderRow.addArrangedSubview(choose)
        folderRow.addArrangedSubview(folderLabel)
        stack.addArrangedSubview(folderRow)
        updateFolderLabel()

        let privacy = NSTextField(wrappingLabelWithString: "隐私：仅申请屏幕录制权限；不联网、不上传、不启用辅助功能、不默认开机启动。")
        privacy.textColor = .secondaryLabelColor
        stack.addArrangedSubview(privacy)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 290)
        ])
    }

    private func checkBox(_ title: String, state: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        return button
    }

    private func shortcutRow(_ title: String, action: HotKeyAction, keyCode: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let label = NSTextField(labelWithString: "\(title)：⌘⇧")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let popup = NSPopUpButton()
        for choice in keyChoices {
            popup.addItem(withTitle: choice.label)
            popup.lastItem?.tag = choice.code
        }
        popup.selectItem(withTag: keyCode)
        popup.tag = Int(action.rawValue)
        popup.target = self
        popup.action = #selector(shortcutChanged(_:))
        shortcutPopups[Int(action.rawValue)] = popup
        row.addArrangedSubview(label)
        row.addArrangedSubview(popup)
        return row
    }

    @objc private func shortcutChanged(_ sender: NSPopUpButton) {
        let code = sender.selectedItem?.tag ?? 18
        let action = HotKeyAction(rawValue: UInt32(sender.tag)) ?? .region
        let existing: [HotKeyAction: Int] = [
            .region: settings.regionKeyCode,
            .fullScreen: settings.fullScreenKeyCode
        ]
        if existing.contains(where: { $0.key != action && $0.value == code }) {
            let alert = NSAlert()
            alert.messageText = "快捷键重复"
            alert.informativeText = "两个截图动作需要使用不同的数字键。"
            alert.runModal()
            sender.selectItem(withTag: existing[action] ?? 18)
            return
        }
        switch action {
        case .region: settings.regionKeyCode = code
        case .fullScreen: settings.fullScreenKeyCode = code
        }
        HotKeyManager.shared.register(settings: settings)
    }

    @objc private func toggleAsk(_ sender: NSButton) { settings.askSaveLocation = sender.state == .on }
    @objc private func toggleCursor(_ sender: NSButton) { settings.includeCursor = sender.state == .on }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSaveDirectory(url)
            settings.askSaveLocation = false
            updateFolderLabel()
        }
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = settings.saveDirectoryURL?.path ?? "未设置（保存时询问）"
        folderLabel.toolTip = settings.saveDirectoryURL?.path
    }
}
