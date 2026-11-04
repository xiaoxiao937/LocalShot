import AppKit
import CoreFoundation
import CoreGraphics
import UniformTypeIdentifiers

enum AppBuildInfo {
    // Snapshot on first launch-time access, so replacing the app bundle cannot
    // make an already-running process display the newly installed version.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    static var display: String { "LocalShot \(version)（构建 \(build)）" }
}

private final class SettingsPageView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        }
    }
}

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
        static let defaultToolRawValue = "defaultToolRawValue"
        static let annotationColorComponents = "annotationColorComponents"
        static let annotationStrokeWidth = "annotationStrokeWidth"
        static let lineStrokeWidth = "annotationStrokeWidth.line"
        static let arrowStrokeWidth = "annotationStrokeWidth.arrow"
        static let rectangleStrokeWidth = "annotationStrokeWidth.rectangle"
        static let ellipseStrokeWidth = "annotationStrokeWidth.ellipse"
        static let penStrokeWidth = "annotationStrokeWidth.pen"
        static let annotationTextSize = "annotationTextSize"
        static let hasShownWelcome = "hasShownWelcome"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.askSaveLocation: true,
            Key.includeCursor: false,
            Key.regionKeyCode: 18,
            Key.fullScreenKeyCode: 20,
            Key.defaultToolRawValue: EditorTool.move.rawValue,
            Key.annotationStrokeWidth: 4.0,
            Key.annotationTextSize: EditorTextSize.medium.rawValue
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

    var defaultTool: EditorTool {
        get { EditorTool(rawValue: defaults.integer(forKey: Key.defaultToolRawValue)) ?? .move }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultToolRawValue) }
    }

    // Only four sRGB components and a bounded set of scalar preferences persist.
    // These values contain no screenshot, annotation text or capture history.
    var annotationColor: NSColor {
        get {
            guard let components = defaults.array(forKey: Key.annotationColorComponents) as? [Double],
                  components.count == 4,
                  components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .systemRed }
            return NSColor(
                srgbRed: CGFloat(components[0]), green: CGFloat(components[1]),
                blue: CGFloat(components[2]), alpha: CGFloat(components[3])
            )
        }
        set {
            guard let color = newValue.usingColorSpace(.sRGB) else { return }
            let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map(Double.init)
            guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
            defaults.set(components, forKey: Key.annotationColorComponents)
        }
    }

    var annotationStrokeWidth: CGFloat {
        get {
            let value = defaults.double(forKey: Key.annotationStrokeWidth)
            return value.isFinite && (1...20).contains(value) ? CGFloat(value) : 4
        }
        set {
            let value = newValue.isFinite ? min(20, max(1, newValue)) : 4
            defaults.set(Double(value), forKey: Key.annotationStrokeWidth)
        }
    }

    func annotationStrokeWidth(for tool: EditorTool) -> CGFloat {
        guard let key = strokeWidthKey(for: tool),
              let storedValue = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(storedValue) != CFBooleanGetTypeID() else { return annotationStrokeWidth }
        let width = storedValue.doubleValue
        return width.isFinite && (1...20).contains(width) ? CGFloat(width) : annotationStrokeWidth
    }

    func setAnnotationStrokeWidth(_ width: CGFloat, for tool: EditorTool) {
        guard let key = strokeWidthKey(for: tool), width.isFinite else { return }
        defaults.set(Double(min(20, max(1, width))), forKey: key)
    }

    private func strokeWidthKey(for tool: EditorTool) -> String? {
        // Fixed keys keep the preference space bounded. The legacy global
        // value remains a migration fallback until each tool is customized.
        switch tool {
        case .line: return Key.lineStrokeWidth
        case .arrow: return Key.arrowStrokeWidth
        case .rectangle: return Key.rectangleStrokeWidth
        case .ellipse: return Key.ellipseStrokeWidth
        case .pen: return Key.penStrokeWidth
        case .move, .text, .mosaic, .crop: return nil
        }
    }

    var annotationTextSize: EditorTextSize {
        get { EditorTextSize(rawValue: defaults.integer(forKey: Key.annotationTextSize)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.annotationTextSize) }
    }

    func recordAnnotationStyle(color: NSColor? = nil, strokeWidth: CGFloat? = nil, textSize: EditorTextSize? = nil) {
        if let color { annotationColor = color }
        if let strokeWidth { annotationStrokeWidth = strokeWidth }
        if let textSize { annotationTextSize = textSize }
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

    var hasSaveDirectory: Bool { defaults.data(forKey: Key.saveDirectoryBookmark) != nil }

    func clearSavedLocationMetadata() {
        defaults.removeObject(forKey: Key.saveDirectoryBookmark)
        defaults.removeObject(forKey: Key.lastSavedPath)
        askSaveLocation = true
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
            "✓ 默认不开机启动，关闭编辑与贴图窗口后释放图片内存"
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
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onQuit: (() -> Void)?
    private let settings: SettingsStore
    private let tabs = NSTabView()
    private let sectionControl = NSSegmentedControl(labels: ["通用", "帮助与支持"], trackingMode: .selectOne, target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "")
    private var askLocationCheckBox: NSButton?
    private var shortcutPopups: [Int: NSPopUpButton] = [:]
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let registrationHint = NSTextField(wrappingLabelWithString: "")
    private var statusObservers: [NSObjectProtocol] = []
    private var permissionRefreshTimer: Timer?
    private let keyChoices: [(label: String, code: Int)] = [
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25)
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalShot 设置"
        window.minSize = NSSize(width: 560, height: 530)
        window.center()
        // The app retains this controller for its entire lifetime. Keep the
        // window object as well so closing and reopening Settings never leaves
        // a controller whose window has already been released.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        observeStatus()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        permissionRefreshTimer?.invalidate()
        for observer in statusObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func showWindow(_ sender: Any?) {
        refreshStatus()
        startPermissionRefresh()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
    }

    func selectHelpTab() {
        sectionControl.selectedSegment = 1
        tabs.selectTabViewItem(at: 1)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let identity = NSStackView()
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2
        let title = NSTextField(labelWithString: "LocalShot")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "本地截图，随手标注")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        identity.addArrangedSubview(title)
        identity.addArrangedSubview(subtitle)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(identity)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(headerSpacer)
        sectionControl.selectedSegment = 0
        sectionControl.target = self
        sectionControl.action = #selector(settingsSectionChanged(_:))
        sectionControl.segmentStyle = .rounded
        header.addArrangedSubview(sectionControl)
        content.addSubview(header)

        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        let footer = buildFooter(in: content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.heightAnchor.constraint(equalToConstant: 42),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])
        let general = addTab("通用", to: tabs)
        buildGeneralUI(in: general)
        let support = addTab("帮助与支持", to: tabs)
        buildStatusUI(in: support)
        buildHelpUI(in: support)
        buildSupportDetails(in: support)
        for stack in [general, support] {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            stack.addArrangedSubview(spacer)
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        }
        refreshStatus()
    }

    @objc private func settingsSectionChanged(_ sender: NSSegmentedControl) {
        tabs.selectTabViewItem(at: max(0, sender.selectedSegment))
    }

    private func buildFooter(in content: NSView) -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(separator)
        let note = NSTextField(labelWithString: "仅本地运行 · 不保留截图历史")
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(note)
        let quitButton = NSButton(title: "退出 LocalShot", target: self, action: #selector(quitApplication))
        quitButton.bezelStyle = .rounded
        quitButton.toolTip = "取消当前截图并完整退出 LocalShot"
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(quitButton)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 28),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -28),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            note.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 28),
            note.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: quitButton.leadingAnchor, constant: -16),
            quitButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -28),
            quitButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return footer
    }

    private func addTab(_ title: String, to tabs: NSTabView) -> NSStackView {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let page = SettingsPageView()
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = page
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        item.view = scroll
        tabs.addTabViewItem(item)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -20),
            page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            page.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ])
        return stack
    }

    private func buildGeneralUI(in stack: NSStackView) {
        let shortcuts = makeCard("快捷键", symbol: "command", in: stack)
        addFullWidth(shortcutRow("区域截图", action: .region, keyCode: settings.regionKeyCode), to: shortcuts)
        addFullWidth(shortcutRow("全屏截图", action: .fullScreen, keyCode: settings.fullScreenKeyCode), to: shortcuts)
        addDescription("打开设置 ⌘⇧0　·　紧急取消 ⌘⇧Esc", to: shortcuts)
        registrationHint.font = .systemFont(ofSize: 11.5)
        registrationHint.textColor = .systemOrange
        addFullWidth(registrationHint, to: shortcuts)

        let capture = makeCard("截图习惯", symbol: "viewfinder", in: stack)
        addFullWidth(defaultToolRow(), to: capture)
        capture.addArrangedSubview(checkBox("全屏截图包含鼠标指针", state: settings.includeCursor, action: #selector(toggleCursor(_:))))

        let saving = makeCard("保存", symbol: "folder", in: stack)
        let askCheckBox = checkBox("保存时询问位置", state: settings.askSaveLocation, action: #selector(toggleAsk(_:)))
        askLocationCheckBox = askCheckBox
        saving.addArrangedSubview(askCheckBox)
        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.alignment = .centerY
        folderRow.spacing = 16
        let folderInfo = NSStackView()
        folderInfo.orientation = .vertical
        folderInfo.alignment = .leading
        folderInfo.spacing = 4
        let folderTitle = NSTextField(labelWithString: "默认保存位置")
        folderTitle.font = .systemFont(ofSize: 13)
        folderInfo.addArrangedSubview(folderTitle)
        folderLabel.font = .systemFont(ofSize: 11.5)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderLabel.toolTip = settings.saveDirectoryURL?.path
        folderInfo.addArrangedSubview(folderLabel)
        folderRow.addArrangedSubview(folderInfo)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        folderRow.addArrangedSubview(spacer)
        let choose = supportButton("选择目录…", action: #selector(chooseFolder))
        folderRow.addArrangedSubview(choose)
        addFullWidth(folderRow, to: saving)
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        updateFolderLabel()
        addDescription("对勾复制截图；只有点击保存才写入图片。", to: saving)
    }

    private func buildStatusUI(in stack: NSStackView) {
        let status = makeCard("运行状态", symbol: "checkmark.shield", in: stack)
        permissionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        addFullWidth(trailingControlRow(label: permissionLabel, control: supportButton("管理权限…", action: #selector(openScreenRecordingSettings))), to: status)
        shortcutStatusLabel.font = .systemFont(ofSize: 12)
        addFullWidth(trailingControlRow(label: shortcutStatusLabel, control: supportButton("重新注册", action: #selector(retryHotKeys))), to: status)
        addDescription("已授权仍无法截图时，请退出并重新打开 LocalShot。", to: status)
    }

    private func buildSupportDetails(in stack: NSStackView) {
        let data = makeCard("隐私与本地数据", symbol: "lock", in: stack)
        addDescription("不联网、不上传、不默认开机启动；仅申请屏幕录制权限。", to: data)
        addDescription("诊断不含截图、识别文字、窗口标题、文件路径或设备标识。", to: data)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.addArrangedSubview(supportButton("导出本地诊断…", action: #selector(exportDiagnostics)))
        actions.addArrangedSubview(supportButton("清除保存位置记录…", action: #selector(clearLocationMetadata)))
        data.addArrangedSubview(actions)
        addDescription("清除记录只移除保存位置，不会删除已保存的截图。", to: data)

        let about = makeCard("当前版本", symbol: "info.circle", in: stack)
        let version = NSTextField(labelWithString: AppBuildInfo.display)
        version.font = .systemFont(ofSize: 13)
        addFullWidth(trailingControlRow(label: version, control: supportButton("在 Finder 中显示", action: #selector(revealRunningApp))), to: about)
        let location = NSTextField(wrappingLabelWithString: Bundle.main.bundleURL.path)
        location.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        location.textColor = .secondaryLabelColor
        location.isSelectable = true
        addFullWidth(location, to: about)
        addDescription("更新后退出旧进程，再重新打开 App，版本才会生效。", to: about)
    }

    private func buildHelpUI(in stack: NSStackView) {
        let help = makeCard("操作速查", symbol: "keyboard", in: stack)
        for (key, meaning) in [
            ("Return", "完成文字输入；未输入时复制并结束"),
            ("⇧ Return", "文字换行，不结束输入"),
            ("⌘ A", "全选正在编辑的文字"),
            ("⌘ Z / ⌘⇧ Z", "撤销 / 重做"),
            ("Esc / ⌘ W / ⌘ .", "取消当前截图"),
            ("⌘⇧ Esc", "紧急关闭截图与贴图"),
            ("⌘⇧0 / ⌘ Q", "打开设置 / 退出 LocalShot")
        ] {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
            keyLabel.widthAnchor.constraint(equalToConstant: 142).isActive = true
            let description = NSTextField(wrappingLabelWithString: meaning)
            description.font = .systemFont(ofSize: 12)
            description.textColor = .secondaryLabelColor
            let row = NSStackView(views: [keyLabel, description])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            addFullWidth(row, to: help)
        }
        let toolKeys = EditorTool.toolbarTools.enumerated().map { "\($0.offset + 1) \($0.element.title)" }.joined(separator: " · ")
        addDescription("数字键切工具：\(toolKeys)。输入文字时正常输入。", to: help)
        addDescription("文字单击拖动、双击编辑；拖右下角自动换行，字号独立调整。任意工具下都能拖动选区边缘，裁剪可撤销。", to: help)
        addDescription("圈定后，用移动工具拖动空白处可调整截图范围；按住空格也可临时移动范围。点对勾才复制完成，钉住的图片仍可自由移动。", to: help)
        addDescription("LocalShot 常驻菜单栏；窗口底部与菜单栏均可完整退出。", to: help)
    }

    private func addDescription(_ text: String, to stack: NSStackView) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeCard(_ title: String, symbol: String, in stack: NSStackView) -> NSStackView {
        let card = SettingsCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 13
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        stack.addArrangedSubview(card)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        content.addArrangedSubview(header)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return content
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func trailingControlRow(label: NSTextField, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(control)
        return row
    }

    private func supportButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func observeStatus() {
        for name in [NSApplication.didBecomeActiveNotification, HotKeyManager.registrationDidChange] {
            statusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            })
        }
    }

    private func startPermissionRefresh() {
        guard permissionRefreshTimer == nil else { return }
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        let granted = CGPreflightScreenCaptureAccess()
        permissionLabel.stringValue = granted ? "屏幕录制已授权" : "屏幕录制需要授权或重启"
        permissionLabel.textColor = granted ? .labelColor : .systemOrange
        let issues = HotKeyManager.shared.registrationIssues
        if issues.isEmpty {
            shortcutStatusLabel.stringValue = "全局快捷键已就绪"
            shortcutStatusLabel.textColor = .labelColor
            registrationHint.stringValue = ""
            registrationHint.isHidden = true
        } else {
            let names = issues.map { $0.action.title }.joined(separator: "、")
            shortcutStatusLabel.stringValue = "未能启用：\(names)。可能被系统或其他应用占用，可换数字键后重试。菜单栏仍可截图。"
            shortcutStatusLabel.textColor = .systemOrange
            registrationHint.stringValue = "有快捷键未能启用，请到“帮助与支持”查看。"
            registrationHint.textColor = .systemOrange
            registrationHint.isHidden = false
        }
    }

    @objc private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func retryHotKeys() {
        HotKeyManager.shared.register(settings: settings)
    }

    @objc private func clearLocationMetadata() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清除保存位置记录？"
        alert.informativeText = "仅清除默认保存目录与最近保存路径，恢复保存时询问位置。已保存的截图不会被删除。"
        alert.addButton(withTitle: "清除记录")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.settings.clearSavedLocationMetadata()
                self?.updateFolderLabel()
            }
        }
    }

    @objc private func exportDiagnostics() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalShot-diagnostics.json"
        panel.title = "导出本地诊断"
        panel.message = "仅导出版本、权限、快捷键和显示器规格；不包含截图、识别文字、文件路径或设备标识。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.writeDiagnostics(to: url) }
        }
    }

    private func writeDiagnostics(to url: URL) {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let displays: [[String: Any]] = NSScreen.screens.map { screen in
            ["widthPoints": Int(screen.frame.width), "heightPoints": Int(screen.frame.height), "backingScale": screen.backingScaleFactor]
        }
        let report: [String: Any] = [
            "schemaVersion": 1,
            "appVersion": AppBuildInfo.version,
            "appBuild": AppBuildInfo.build,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "screenRecordingAuthorized": CGPreflightScreenCaptureAccess(),
            "shortcutIssues": HotKeyManager.shared.registrationIssues.map { ["action": $0.action.title, "status": String($0.status)] },
            "displays": displays,
            "settings": ["askSaveLocation": settings.askSaveLocation, "includeCursor": settings.includeCursor, "saveDirectoryConfigured": settings.hasSaveDirectory, "defaultTool": settings.defaultTool.title] as [String: Any],
            "privacy": ["screenshotHistory": false, "network": false, "automaticDiagnosticStorage": false]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "诊断文件未能保存"
            alert.informativeText = "请重新选择一个可写入的位置。"
            alert.beginSheetModal(for: window)
        }
    }

    private func checkBox(_ title: String, state: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        return button
    }

    private func shortcutRow(_ title: String, action: HotKeyAction, keyCode: Int) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.widthAnchor.constraint(equalToConstant: 58).isActive = true
        for choice in keyChoices {
            popup.addItem(withTitle: choice.label)
            popup.lastItem?.tag = choice.code
        }
        popup.selectItem(withTag: keyCode)
        popup.tag = Int(action.rawValue)
        popup.target = self
        popup.action = #selector(shortcutChanged(_:))
        shortcutPopups[Int(action.rawValue)] = popup
        let modifiers = NSTextField(labelWithString: "⌘⇧")
        modifiers.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        modifiers.textColor = .secondaryLabelColor
        let control = NSStackView(views: [modifiers, popup])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 6
        return trailingControlRow(label: label, control: control)
    }

    private func defaultToolRow() -> NSView {
        let label = NSTextField(labelWithString: "截图后默认工具")
        label.font = .systemFont(ofSize: 13)
        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        for tool in EditorTool.toolbarTools {
            popup.addItem(withTitle: tool.title)
            popup.lastItem?.tag = tool.rawValue
        }
        popup.selectItem(withTag: settings.defaultTool.rawValue)
        popup.target = self
        popup.action = #selector(defaultToolChanged(_:))
        return trailingControlRow(label: label, control: popup)
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
        case .settings, .emergencyCancel: return
        }
        HotKeyManager.shared.register(settings: settings)
        if HotKeyManager.shared.registrationIssues.contains(where: { $0.action == action }) {
            switch action {
            case .region: settings.regionKeyCode = existing[action] ?? 18
            case .fullScreen: settings.fullScreenKeyCode = existing[action] ?? 20
            case .settings, .emergencyCancel: break
            }
            sender.selectItem(withTag: existing[action] ?? 18)
            HotKeyManager.shared.register(settings: settings)
            let alert = NSAlert()
            alert.messageText = "这个快捷键暂时无法使用"
            alert.informativeText = "它可能已被系统或其他应用占用。已恢复原来的设置，请换一个数字键。"
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    @objc private func toggleAsk(_ sender: NSButton) { settings.askSaveLocation = sender.state == .on }
    @objc private func toggleCursor(_ sender: NSButton) { settings.includeCursor = sender.state == .on }
    @objc private func defaultToolChanged(_ sender: NSPopUpButton) {
        settings.defaultTool = EditorTool(rawValue: sender.selectedItem?.tag ?? EditorTool.move.rawValue) ?? .move
    }

    @objc private func quitApplication() {
        onQuit?()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSaveDirectory(url)
            settings.askSaveLocation = false
            askLocationCheckBox?.state = .off
            updateFolderLabel()
        }
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = settings.saveDirectoryURL?.path ?? "未设置（保存时询问）"
        folderLabel.toolTip = settings.saveDirectoryURL?.path
        askLocationCheckBox?.state = settings.askSaveLocation ? .on : .off
    }
}
