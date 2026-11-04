import AppKit

/// Shared chrome for selection and annotation. Dimensions stay unchanged when
/// tool-specific controls change, keeping completion actions under the pointer.
@MainActor
enum CaptureAppearance {
    static let toolbarHeight: CGFloat = 46
    static let toolbarCornerRadius: CGFloat = 14
    static let inputCornerRadius: CGFloat = 10
    static let panelCornerRadius: CGFloat = 16
    static let badgeCornerRadius: CGFloat = 12
    static let toolbarSpacing: CGFloat = 6
    static let toolbarHorizontalPadding: CGFloat = 8
    static let toolbarSeparatorHeight: CGFloat = 20
    static let toolbarScreenInset: CGFloat = 8
    static let selectionCornerRadius: CGFloat = 4
    static let selectionLineWidth: CGFloat = 0.75
    static let selectionDarkLineWidth: CGFloat = 1
    static let handleDiameter: CGFloat = 7
    static var selectionColor: NSColor { NSColor(calibratedWhite: 0.94, alpha: 1) }
    static var selectionLightOutline: NSColor { NSColor.white.withAlphaComponent(0.9) }
    static var selectionDarkOutline: NSColor { NSColor.black.withAlphaComponent(0.62) }

    static func toolbarBackground(frame: NSRect, host: NSView) -> NSView {
        surfaceBackground(frame: frame, host: host, cornerRadius: toolbarCornerRadius)
    }

    /// Chrome only: callers retain their host's layout and keep screenshot
    /// pixels in a separate, unmodified rendering/export path.
    static func surfaceBackground(frame: NSRect, host: NSView, cornerRadius: CGFloat) -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = CaptureSolidSurfaceView(frame: frame)
            solid.autoresizingMask = [.width, .height]
            solid.layer?.cornerRadius = cornerRadius
            solid.layer?.masksToBounds = true
            solid.addSubview(host)
            return solid
        }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = host
            return glass
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(host)
        return effect
    }

    static func styleButton(_ button: NSButton, primary: Bool = false) {
        button.bezelStyle = primary ? .rounded : .toolbar
        button.imagePosition = .imageOnly
        button.contentTintColor = primary ? .systemGreen : .labelColor
        if primary { button.bezelColor = NSColor.systemGreen.withAlphaComponent(0.15) }
        if let label = button.toolTip { button.setAccessibilityLabel(label) }
    }
}

@MainActor
private final class CaptureSolidSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateSurfaceColor()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColor()
    }

    private func updateSurfaceColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

/// Noninteractive chrome for region hints and dimensions. Changing its text
/// changes fitting size only; positioning remains with the selection view.
@MainActor
final class CaptureGlassLabelView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let host = NSView()
    private var surface: NSView?
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat

    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var font: NSFont {
        get { label.font ?? .systemFont(ofSize: 11.5) }
        set {
            label.font = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(
        text: String,
        font: NSFont = .systemFont(ofSize: 11.5),
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 7
    ) {
        self.horizontalPadding = max(0, horizontalPadding)
        self.verticalPadding = max(0, verticalPadding)
        super.init(frame: .zero)
        label.stringValue = text
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        host.autoresizingMask = [.width, .height]
        host.addSubview(label)
        frame.size = intrinsicContentSize
        host.frame = bounds
        let shell = CaptureAppearance.surfaceBackground(
            frame: bounds, host: host, cornerRadius: CaptureAppearance.badgeCornerRadius
        )
        shell.autoresizingMask = [.width, .height]
        surface = shell
        addSubview(shell)
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(
            width: ceil(max(0, size.width)) + horizontalPadding * 2,
            height: max(24, ceil(max(0, size.height)) + verticalPadding * 2)
        )
    }

    override func layout() {
        super.layout()
        surface?.frame = bounds
        host.frame = bounds
        let height = ceil(max(0, label.intrinsicContentSize.height))
        label.frame = NSRect(
            x: horizontalPadding, y: floor((bounds.height - height) / 2),
            width: max(0, bounds.width - horizontalPadding * 2), height: height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A normal color well with a deliberately small first-level palette. The
/// inherited color/target/action API also keeps native color drag/drop intact.
@MainActor
final class CaptureColorWell: NSColorWell, NSPopoverDelegate {
    var onPaletteClose: (() -> Void)?
    private var colorPopover: NSPopover?
    private var systemPanelOriginalLevel: NSWindow.Level?
    private var systemPanelCloseObserver: NSObjectProtocol?
    private var applicationInactiveObserver: NSObjectProtocol?
    private var isOpeningSystemPanel = false

    var isPaletteOpen: Bool { colorPopover?.isShown == true || systemPanelOriginalLevel != nil }
    var paletteWindow: NSWindow? {
        // The old popover may still be animating closed after More Colors
        // has already made the system panel key. Ownership follows the panel.
        if systemPanelOriginalLevel != nil { return NSColorPanel.shared }
        if let colorPopover, colorPopover.isShown { return colorPopover.contentViewController?.view.window }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        colorWellStyle = .minimal
        supportsAlpha = false
        pulldownTarget = self
        pulldownAction = #selector(togglePalette(_:))
        setAccessibilityLabel("标注颜色")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let systemPanelCloseObserver { NotificationCenter.default.removeObserver(systemPanelCloseObserver) }
        if let applicationInactiveObserver { NotificationCenter.default.removeObserver(applicationInactiveObserver) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dismissPalette() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func deactivate() {
        let hadSystemPanel = systemPanelOriginalLevel != nil
        colorPopover?.performClose(nil)
        restoreSystemPanel(hide: hadSystemPanel)
        super.deactivate()
    }

    /// Session close and app deactivation use the same cleanup. A temporary
    /// raise of the shared system color panel is always restored here.
    func dismissPalette() {
        let hadSystemPanel = systemPanelOriginalLevel != nil
        colorPopover?.performClose(nil)
        restoreSystemPanel(hide: hadSystemPanel)
        super.deactivate()
        if hadSystemPanel { onPaletteClose?() }
    }

    @objc private func togglePalette(_ sender: Any?) {
        guard isEnabled, !isHidden, window != nil else { return }
        if colorPopover?.isShown == true {
            colorPopover?.performClose(nil)
            return
        }
        if systemPanelOriginalLevel != nil {
            restoreSystemPanel(hide: true)
            super.deactivate()
        }
        let controller = CaptureColorPaletteController(color: color)
        controller.onChooseColor = { [weak self] color in
            guard let self else { return }
            self.color = color
            self.sendAction(self.action, to: self.target)
            self.colorPopover?.performClose(nil)
        }
        controller.onMoreColors = { [weak self] in self?.showSystemPanel() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 212, height: 152)
        popover.contentViewController = controller
        popover.delegate = self
        colorPopover = popover
        observeApplicationDeactivation()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func showSystemPanel() {
        isOpeningSystemPanel = true
        colorPopover?.performClose(nil)
        super.activate(true)
        let panel = NSColorPanel.shared
        systemPanelOriginalLevel = panel.level
        if let ownerWindow = window {
            panel.level = NSWindow.Level(rawValue: max(panel.level.rawValue, ownerWindow.level.rawValue + 1))
        }
        systemPanelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemPanelClosing() }
        }
        observeApplicationDeactivation()
        panel.makeKeyAndOrderFront(nil)
        isOpeningSystemPanel = false
    }

    private func systemPanelClosing() {
        guard systemPanelOriginalLevel != nil else { return }
        restoreSystemPanel(hide: false)
        super.deactivate()
        onPaletteClose?()
    }

    private func restoreSystemPanel(hide: Bool) {
        guard let originalLevel = systemPanelOriginalLevel else {
            stopObservingIfClosed()
            return
        }
        systemPanelOriginalLevel = nil
        if let systemPanelCloseObserver {
            NotificationCenter.default.removeObserver(systemPanelCloseObserver)
            self.systemPanelCloseObserver = nil
        }
        let panel = NSColorPanel.shared
        panel.level = originalLevel
        if hide { panel.orderOut(nil) }
        stopObservingIfClosed()
    }

    private func observeApplicationDeactivation() {
        guard applicationInactiveObserver == nil else { return }
        applicationInactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPalette() }
        }
    }

    private func stopObservingIfClosed() {
        guard colorPopover?.isShown != true, systemPanelOriginalLevel == nil else { return }
        if let applicationInactiveObserver {
            NotificationCenter.default.removeObserver(applicationInactiveObserver)
            self.applicationInactiveObserver = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === colorPopover else { return }
        colorPopover = nil
        stopObservingIfClosed()
        if !isOpeningSystemPanel, systemPanelOriginalLevel == nil { onPaletteClose?() }
    }
}

@MainActor
private final class CaptureColorPaletteController: NSViewController {
    var onChooseColor: ((NSColor) -> Void)?
    var onMoreColors: (() -> Void)?
    private let currentColor: NSColor
    private let choices: [(String, NSColor)] = [
        ("红色", .systemRed), ("橙色", .systemOrange), ("黄色", .systemYellow),
        ("绿色", .systemGreen), ("青色", .systemCyan), ("蓝色", .systemBlue),
        ("紫色", .systemPurple), ("粉色", .systemPink), ("黑色", .black), ("白色", .white)
    ]

    init(color: NSColor) {
        currentColor = color
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 212, height: 152))
        host.autoresizingMask = [.width, .height]
        view = CaptureAppearance.surfaceBackground(
            frame: host.bounds, host: host, cornerRadius: CaptureAppearance.panelCornerRadius
        )
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        let title = NSTextField(labelWithString: "标注颜色")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for rowIndex in 0..<2 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            for index in (rowIndex * 5)..<(rowIndex * 5 + 5) {
                let choice = choices[index]
                let swatch = CaptureColorSwatchButton(color: choice.1, name: choice.0, selected: colorsMatch(choice.1, currentColor))
                swatch.tag = index
                swatch.target = self
                swatch.action = #selector(pickColor(_:))
                row.addArrangedSubview(swatch)
            }
            stack.addArrangedSubview(row)
        }
        let more = NSButton(title: "更多颜色…", target: self, action: #selector(moreColors(_:)))
        more.bezelStyle = .inline
        more.controlSize = .small
        more.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(more)
        more.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -14)
        ])
    }

    private func colorsMatch(_ first: NSColor, _ second: NSColor) -> Bool {
        guard let first = first.usingColorSpace(.sRGB), let second = second.usingColorSpace(.sRGB) else { return false }
        return abs(first.redComponent - second.redComponent) < 0.01
            && abs(first.greenComponent - second.greenComponent) < 0.01
            && abs(first.blueComponent - second.blueComponent) < 0.01
    }

    @objc private func pickColor(_ sender: NSButton) { onChooseColor?(choices[sender.tag].1) }
    @objc private func moreColors(_ sender: NSButton) { onMoreColors?() }
}

@MainActor
private final class CaptureColorSwatchButton: NSButton {
    private let swatchColor: NSColor
    private let isCurrent: Bool

    init(color: NSColor, name: String, selected: Bool) {
        swatchColor = color
        isCurrent = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        setButtonType(.momentaryChange)
        isBordered = false
        title = ""
        toolTip = name
        setAccessibilityLabel(name + (selected ? "，当前颜色" : ""))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        (isHighlighted ? swatchColor.withAlphaComponent(0.75) : swatchColor).setFill()
        circle.fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
        if isCurrent || window?.firstResponder === self {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            NSColor.labelColor.withAlphaComponent(isCurrent ? 0.8 : 0.45).setStroke()
            ring.lineWidth = 1.25
            ring.stroke()
        }
    }
}

@MainActor
final class CaptureStyleControlsView: NSView {
    private let colorWell: NSColorWell
    private let widthSlider: NSSlider
    private let textSizeControl: NSSegmentedControl
    private let hint = NSTextField(labelWithString: "移动")
    private var displayedTool: EditorTool?

    init(colorWell: NSColorWell, widthSlider: NSSlider, textSizeControl: NSSegmentedControl) {
        self.colorWell = colorWell
        self.widthSlider = widthSlider
        self.textSizeControl = textSizeControl
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        colorWell.colorWellStyle = .minimal
        for view in [colorWell, widthSlider, textSizeControl, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 128),
            heightAnchor.constraint(equalToConstant: 30),
            colorWell.leadingAnchor.constraint(equalTo: leadingAnchor),
            colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 28),
            colorWell.heightAnchor.constraint(equalToConstant: 28),
            textSizeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            textSizeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            textSizeControl.widthAnchor.constraint(equalToConstant: 88),
            textSizeControl.heightAnchor.constraint(equalToConstant: 26),
            widthSlider.centerXAnchor.constraint(equalTo: textSizeControl.centerXAnchor),
            widthSlider.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthSlider.widthAnchor.constraint(equalToConstant: 72),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(tool: .move)
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 30) }

    func update(tool: EditorTool, selectedTool: EditorTool? = nil) {
        let effectiveTool = tool == .move ? (selectedTool ?? .move) : tool
        guard displayedTool != effectiveTool else { return }
        displayedTool = effectiveTool
        let text = effectiveTool == .text
        let stroke = [EditorTool.arrow, .line, .rectangle, .ellipse, .pen].contains(effectiveTool)
        if !(text || stroke), !colorWell.isHidden { (colorWell as? CaptureColorWell)?.dismissPalette() }
        colorWell.isHidden = !(text || stroke)
        widthSlider.isHidden = !stroke
        textSizeControl.isHidden = !text
        colorWell.isEnabled = text || stroke
        widthSlider.isEnabled = stroke
        textSizeControl.isEnabled = text
        hint.isHidden = text || stroke
        switch effectiveTool {
        case .mosaic:
            hint.stringValue = "马赛克"
            hint.toolTip = "拖动涂抹遮挡"
        case .crop:
            hint.stringValue = "裁剪"
            hint.toolTip = "拖动裁剪范围"
        default:
            hint.stringValue = "移动"
            hint.toolTip = "拖动调整截图范围"
        }
    }
}

/// A shared, noninteractive toast surface. Busy OCR keeps its own actionable
/// cancel control; these transient messages never take keyboard or mouse input.
@MainActor
final class CaptureToastView: NSView {
    private var preferredSize = NSSize(width: 180, height: 38)
    private var contentSize = NSSize.zero
    private var contentRow: NSStackView?
    private var surface: NSView?
    override var intrinsicContentSize: NSSize { preferredSize }

    init(title: String, message: String = "", symbol: String = "checkmark.circle.fill") {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = symbol.contains("exclamation") ? .systemOrange : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = .labelColor
        let labels = NSStackView(views: [titleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        if !message.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: message)
            detail.font = .systemFont(ofSize: 11.5)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 280
            labels.addArrangedSubview(detail)
        }
        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            labels.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])
        let fitting = row.fittingSize
        contentSize = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        preferredSize = NSSize(width: max(184, contentSize.width + 26), height: max(46, contentSize.height + 20))
        frame.size = preferredSize
        // The glass is only the surface. Center the icon and text as a
        // group in the final panel bounds, including the minimum-width case.
        let background = CaptureAppearance.toolbarBackground(frame: bounds, host: NSView(frame: bounds))
        surface = background
        contentRow = row
        addSubview(background)
        addSubview(row)
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        surface?.frame = bounds
        let width = min(contentSize.width, max(1, bounds.width - 26))
        contentRow?.frame = NSRect(
            x: bounds.midX - width / 2, y: bounds.midY - contentSize.height / 2,
            width: width, height: contentSize.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
