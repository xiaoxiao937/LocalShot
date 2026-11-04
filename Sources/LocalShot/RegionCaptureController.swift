import AppKit

final class CaptureOverlayWindow: NSWindow {
    var acceptsKeyEvents = true
    override var canBecomeKey: Bool { acceptsKeyEvents }
    override var canBecomeMain: Bool { acceptsKeyEvents }
}

enum RegionCaptureAction {
    case edit(
        tool: EditorTool,
        color: NSColor,
        width: CGFloat,
        textSize: EditorTextSize,
        gesture: EditorInitialGesture? = nil
    )
    case recognizeText
    case pin
    case save
    case finish
}

enum EditorInitialGesture {
    case tap(CGPoint)
    case drag(from: CGPoint, to: CGPoint)
    case freehand([CGPoint])
}

struct RegionCaptureRequest {
    let selection: CGRect
    let action: RegionCaptureAction
}

@MainActor
final class RegionCaptureController: NSObject {
    var onComplete: ((RegionCaptureRequest) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private let window: CaptureOverlayWindow
    private let selectionView: RegionSelectionView
    private let defaultTool: EditorTool
    private let settings: SettingsStore
    private var toolbarView: NSView?
    private enum ToolbarPlacement { case below, above, inside }
    private var toolbarPlacement: ToolbarPlacement?
    private let colorWell = CaptureColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let textSizeControl = NSSegmentedControl(
        labels: EditorTextSize.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private lazy var styleControls = CaptureStyleControlsView(
        colorWell: colorWell, widthSlider: widthSlider, textSizeControl: textSizeControl
    )
    private var toolButtons: [NSButton] = []
    private var escapeMonitor: Any?
    private var safetyTimeout: DispatchWorkItem?
    private var handoffTimeout: DispatchWorkItem?
    private var didFinish = false
    private var hasSelection = false
    private var cursorIsPushed = false

    init(
        screen: NSScreen,
        windowCandidates: [CGRect],
        frozenDisplay: CapturedImage,
        defaultTool: EditorTool,
        settings: SettingsStore
    ) {
        self.screen = screen
        self.defaultTool = defaultTool
        self.settings = settings
        window = CaptureOverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let visible = screen.visibleFrame
        let safeInsets = NSEdgeInsets(
            top: max(0, screen.frame.maxY - visible.maxY),
            left: max(0, visible.minX - screen.frame.minX),
            bottom: max(0, visible.minY - screen.frame.minY),
            right: max(0, screen.frame.maxX - visible.maxX)
        )
        selectionView = RegionSelectionView(
            windowCandidates: windowCandidates,
            frozenDisplay: frozenDisplay,
            safeInsets: safeInsets
        )
        super.init()

        window.contentView = selectionView
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.animationBehavior = .none
        window.hasShadow = false
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false

        buildToolbar()

        selectionView.onSelectionChanged = { [weak self] selection in
            self?.selectionDidChange(selection)
        }
        selectionView.onSelectionCommitted = { [weak self] in
            guard let self else { return }
            // The first click/drag opens the editor at the initial viewport.
            self.completeCapture(action: .edit(
                tool: self.defaultTool,
                color: self.colorWell.color,
                width: self.widthSlider.doubleValue,
                textSize: self.selectedTextSize,
                gesture: nil
            ))
        }
        selectionView.onToolGesture = { [weak self] tool, gesture in
            guard let self else { return }
            self.completeCapture(action: .edit(
                tool: tool,
                color: self.colorWell.color,
                width: self.widthSlider.doubleValue,
                textSize: self.selectedTextSize,
                gesture: gesture
            ))
        }
        selectionView.onConfirm = { [weak self] in
            self?.completeCapture(action: .finish)
        }
        selectionView.onCancel = { [weak self] in
            self?.cancelCapture()
        }
    }

    func show() {
        window.acceptsKeyEvents = true
        window.hidesOnDeactivate = true
        window.ignoresMouseEvents = false
        installEscapeMonitor()
        installSafetyTimeout()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        toolbarView?.isHidden = true
        // Prepare the initial highlight and frozen surface before ordering
        // the window. Do not show a dark-only frame awaiting a mouse event.
        selectionView.prepareInitialHover(at: window.convertPoint(fromScreen: NSEvent.mouseLocation))
        selectionView.layoutSubtreeIfNeeded()
        window.display()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(selectionView)
        NSCursor.crosshair.push()
        cursorIsPushed = true
    }

    private func releaseInteraction() {
        colorWell.dismissPalette()
        selectionView.setTemporaryMove(false)
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        safetyTimeout?.cancel()
        safetyTimeout = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        if cursorIsPushed {
            NSCursor.pop()
            cursorIsPushed = false
        }
        // These are WindowServer-level gates. Even if asynchronous capture or
        // app state later fails, this visual handoff can no longer receive a
        // mouse event or become the key/main window.
        window.ignoresMouseEvents = true
        window.acceptsKeyEvents = false
        window.resignKey()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        releaseInteraction()
        toolbarView?.isHidden = true
        window.orderOut(nil)
    }

    private func beginSafeHandoff() {
        guard !didFinish else { return }
        didFinish = true
        releaseInteraction()
        // Keep the already-rendered selection visible while the editor is
        // prepared from the frozen image. The window is now visual-only, and this
        // independent deadline removes it even if the coordinator never calls
        // back because the framework or app state fails unexpectedly.
        window.hidesOnDeactivate = false
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.dismissHandoff() }
        }
        handoffTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    func dismissHandoff() {
        handoffTimeout?.cancel()
        handoffTimeout = nil
        toolbarView?.isHidden = true
        window.ignoresMouseEvents = true
        window.acceptsKeyEvents = false
        window.orderOut(nil)
    }

    func retainAsEditorBackdrop() {
        handoffTimeout?.cancel()
        handoffTimeout = nil
        toolbarView?.isHidden = true
        selectionView.enterBackdropMode()
        // The editor is raised to statusBar level; this frozen backdrop stays
        // one level lower and never receives input. If LocalShot loses focus,
        // AppKit hides it so a frozen desktop can never strand the user.
        window.level = .floating
        window.hidesOnDeactivate = true
        window.ignoresMouseEvents = true
        window.acceptsKeyEvents = false
    }

    func showEditorBackdrop(selection globalScreenRect: CGRect) {
        retainAsEditorBackdrop()
        updateBackdropSelection(to: globalScreenRect)
        window.displayIfNeeded()
        window.orderFrontRegardless()
    }

    func setBackdropVisible(_ visible: Bool) {
        // These gates hold even when a settings or OCR window changes key
        // status within LocalShot, without discarding the capture session.
        window.ignoresMouseEvents = true
        window.acceptsKeyEvents = false
        if visible {
            window.displayIfNeeded()
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    func updateBackdropSelection(to globalScreenRect: CGRect) {
        let localRect = CGRect(
            x: globalScreenRect.minX - screen.frame.minX,
            y: screen.frame.maxY - globalScreenRect.maxY,
            width: globalScreenRect.width,
            height: globalScreenRect.height
        )
        selectionView.updateBackdropSelection(localRect)
    }

    private func selectionDidChange(_ selection: CGRect?) {
        guard !didFinish else { return }
        guard let selection else {
            hasSelection = false
            toolbarPlacement = nil
            toolbarView?.isHidden = true
            return
        }
        if !hasSelection {
            hasSelection = true
            setPendingTool(defaultTool)
            // The selection-commit callback immediately creates the editor,
            // which owns the toolbar. Do not flash this preview toolbar first.
            return
        }
        positionToolbar(for: selection)
        toolbarView?.isHidden = false
    }

    private func completeCapture(action: RegionCaptureAction) {
        guard !didFinish,
              let selection = selectionView.currentSelection else { return }
        let completion = onComplete
        let request = RegionCaptureRequest(selection: selection, action: action)
        // The visual handoff remains on screen to avoid a blank desktop frame,
        // but it is stripped of both mouse and keyboard eligibility before the
        // asynchronous callback can start.
        beginSafeHandoff()
        completion?(request)
    }

    private func cancelCapture() {
        guard !didFinish else { return }
        let cancellation = onCancel
        finish()
        cancellation?()
    }

    func cancel() {
        if didFinish {
            dismissHandoff()
        } else {
            cancelCapture()
        }
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        cancelCapture()
    }

    private func installSafetyTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.cancelCapture() }
        }
        safetyTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: workItem)
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .keyUp {
                if event.keyCode == 49, self.selectionView.isTemporarilyMoving {
                    self.selectionView.setTemporaryMove(false)
                    return nil
                }
                return event
            }
            let character = event.charactersIgnoringModifiers?.lowercased()
            let isCommandCancel = flags.contains(.command)
                && (character == "." || character == "w")
            if event.keyCode == 53, self.colorWell.isPaletteOpen {
                self.colorWell.dismissPalette()
                return nil
            }
            if event.keyCode == 53 || isCommandCancel {
                self.cancelCapture()
                return nil
            }
            guard !flags.contains(.command),
                  !flags.contains(.control),
                  !flags.contains(.option),
                  self.window.isKeyWindow,
                  self.window.firstResponder === self.selectionView,
                  self.selectionView.currentSelection != nil else { return event }
            if event.keyCode == 49 {
                self.selectionView.setTemporaryMove(true)
                return nil
            }
            if (123...126).contains(event.keyCode) {
                let step: CGFloat = flags.contains(.shift) ? 10 : 1
                switch event.keyCode {
                case 123: self.selectionView.nudgeSelection(dx: -step, dy: 0)
                case 124: self.selectionView.nudgeSelection(dx: step, dy: 0)
                case 125: self.selectionView.nudgeSelection(dx: 0, dy: step)
                default: self.selectionView.nudgeSelection(dx: 0, dy: -step)
                }
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                self.completeCapture(action: .finish)
                return nil
            }
            if let character = event.charactersIgnoringModifiers,
               let number = Int(character),
               EditorTool.toolbarTools.indices.contains(number - 1) {
                let tool = EditorTool.toolbarTools[number - 1]
                self.setPendingTool(tool)
                return nil
            }
            return event
        }
    }

    private func buildToolbar() {
        let toolGroup = toolbarGroup()
        for (index, tool) in EditorTool.toolbarTools.enumerated() {
            let button = iconButton(
                symbol: tool.symbolName,
                tip: "\(index + 1) · \(tool.title)",
                action: #selector(selectTool(_:))
            )
            button.tag = tool.rawValue
            button.setButtonType(.toggle)
            button.state = tool == defaultTool ? .on : .off
            toolButtons.append(button)
            toolGroup.addArrangedSubview(button)
        }

        let styleGroup = styleControls
        colorWell.color = settings.annotationColor
        colorWell.target = self
        colorWell.action = #selector(styleChanged(_:))
        colorWell.toolTip = "标注颜色"
        colorWell.onPaletteClose = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFinish, NSApp.isActive,
                      self.window.isVisible else { return }
                if let keyWindow = NSApp.keyWindow, keyWindow !== self.window { return }
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.selectionView)
            }
        }
        let initialWidth = settings.annotationStrokeWidth(for: defaultTool)
        widthSlider.doubleValue = initialWidth
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged(_:))
        widthSlider.toolTip = "线条粗细"
        widthSlider.isContinuous = false

        textSizeControl.selectedSegment = settings.annotationTextSize.rawValue
        textSizeControl.target = self
        textSizeControl.action = #selector(textSizeChanged)
        textSizeControl.toolTip = "文字大小：小 / 中 / 大"
        styleControls.update(tool: defaultTool)
        selectionView.activeTool = defaultTool
        selectionView.activeColor = settings.annotationColor
        selectionView.activeWidth = initialWidth

        let editActionGroup = toolbarGroup()
        let undoButton = iconButton(symbol: "arrow.uturn.backward", tip: "进入标注后可撤销", action: #selector(noAction))
        let redoButton = iconButton(symbol: "arrow.uturn.forward", tip: "进入标注后可重做", action: #selector(noAction))
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        editActionGroup.addArrangedSubview(undoButton)
        editActionGroup.addArrangedSubview(redoButton)
        editActionGroup.addArrangedSubview(iconButton(symbol: "text.viewfinder", tip: "提取文字", action: #selector(recognizeText)))
        editActionGroup.addArrangedSubview(iconButton(symbol: "pin", tip: "贴图", action: #selector(pinImage)))

        let completionGroup = toolbarGroup()
        completionGroup.addArrangedSubview(iconButton(symbol: "square.and.arrow.down", tip: "下载 PNG", action: #selector(saveImage)))
        let finishButton = iconButton(symbol: "checkmark", tip: "复制并完成", action: #selector(finishSelection))
        CaptureAppearance.styleButton(finishButton, primary: true)
        completionGroup.addArrangedSubview(finishButton)
        let cancelButton = iconButton(symbol: "xmark", tip: "取消", action: #selector(cancelSelection))
        completionGroup.addArrangedSubview(cancelButton)

        let groups: [NSView] = [
            toolGroup,
            toolbarSeparator(),
            styleGroup,
            toolbarSeparator(),
            editActionGroup,
            toolbarSeparator(),
            completionGroup
        ]
        let toolbar = NSStackView(views: groups)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = CaptureAppearance.toolbarSpacing

        toolbar.layoutSubtreeIfNeeded()
        let padding = CaptureAppearance.toolbarHorizontalPadding * 2
        let maximumWidth = max(240, screen.visibleFrame.width - CaptureAppearance.toolbarScreenInset * 2)
        if toolbar.fittingSize.width + padding > maximumWidth {
            // Small screens get two rows rather than offscreen controls.
            groups.forEach {
                toolbar.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            let top = NSStackView(views: [toolGroup, toolbarSeparator(), styleGroup])
            let bottom = NSStackView(views: [editActionGroup, toolbarSeparator(), completionGroup])
            for row in [top, bottom] {
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 8
                toolbar.addArrangedSubview(row)
            }
            toolbar.orientation = .vertical
            toolbar.alignment = .centerX
            if top.fittingSize.width + padding > maximumWidth {
                top.removeArrangedSubview(styleGroup)
                styleGroup.removeFromSuperview()
                toolbar.insertArrangedSubview(styleGroup, at: 1)
            }
            toolbar.layoutSubtreeIfNeeded()
        }
        let fitting = toolbar.fittingSize
        let contentSize = CGSize(width: ceil(fitting.width) + padding, height: max(CaptureAppearance.toolbarHeight, ceil(fitting.height) + 16))
        let host = NSView(frame: NSRect(origin: .zero, size: contentSize))
        host.autoresizingMask = [.width, .height]
        toolbar.frame = NSRect(
            x: CaptureAppearance.toolbarHorizontalPadding,
            y: floor((contentSize.height - fitting.height) / 2),
            width: fitting.width,
            height: fitting.height
        )
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        host.addSubview(toolbar)
        let background = toolbarBackground(frame: NSRect(origin: .zero, size: contentSize), host: host)
        background.isHidden = true
        selectionView.addSubview(background)
        toolbarView = background
    }

    private func positionToolbar(for selection: CGRect) {
        guard let toolbarView else { return }
        var toolbarFrame = toolbarView.frame
        let horizontalInset = CaptureAppearance.toolbarScreenInset
        let visible = screen.visibleFrame
        let localVisibleMinX = visible.minX - screen.frame.minX
        let localVisibleMaxX = visible.maxX - screen.frame.minX
        let localVisibleMinY = screen.frame.maxY - visible.maxY
        let localVisibleMaxY = screen.frame.maxY - visible.minY
        let centeredX = selection.midX - toolbarFrame.width / 2
        let minimumX = localVisibleMinX + horizontalInset
        let maximumX = localVisibleMaxX - toolbarFrame.width - horizontalInset
        toolbarFrame.origin.x = maximumX >= minimumX
            ? min(max(centeredX, minimumX), maximumX)
            : (localVisibleMinX + localVisibleMaxX - toolbarFrame.width) / 2
        if !selectionView.isAdjustingSelection || toolbarPlacement == nil {
            if selection.maxY + toolbarFrame.height + 8 <= localVisibleMaxY - 8 {
                toolbarPlacement = .below
            } else if selection.minY - toolbarFrame.height - 8 >= localVisibleMinY + 8 {
                toolbarPlacement = .above
            } else {
                toolbarPlacement = .inside
            }
        }
        let proposedY: CGFloat
        switch toolbarPlacement ?? .inside {
        case .below: proposedY = selection.maxY + 8
        case .above: proposedY = selection.minY - toolbarFrame.height - 8
        case .inside: proposedY = localVisibleMaxY - toolbarFrame.height - 8
        }
        toolbarFrame.origin.y = min(
            max(proposedY, localVisibleMinY + 8),
            max(localVisibleMinY + 8, localVisibleMaxY - toolbarFrame.height - 8)
        )
        toolbarView.frame = toolbarFrame
    }

    private func toolbarGroup(spacing: CGFloat = 4) -> NSStackView {
        let group = NSStackView()
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = spacing
        return group
    }

    private func toolbarSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: CaptureAppearance.toolbarSeparatorHeight).isActive = true
        separator.alphaValue = 0.45
        return separator
    }

    private func toolbarBackground(frame: NSRect, host: NSView) -> NSView {
        CaptureAppearance.toolbarBackground(frame: frame, host: host)
    }

    private func iconButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tip
        CaptureAppearance.styleButton(button)
        button.setAccessibilityLabel(tip)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = EditorTool(rawValue: sender.tag) else { return }
        setPendingTool(tool)
    }

    private func setPendingTool(_ tool: EditorTool) {
        selectionView.activeTool = tool
        let width = settings.annotationStrokeWidth(for: tool)
        if widthSlider.doubleValue != width { widthSlider.doubleValue = width }
        selectionView.activeWidth = width
        toolButtons.forEach { $0.state = ($0.tag == tool.rawValue) ? .on : .off }
        styleControls.update(tool: tool)
        window.makeFirstResponder(selectionView)
    }

    @objc private func styleChanged(_ sender: NSControl) {
        if sender === colorWell {
            selectionView.activeColor = colorWell.color
            settings.annotationColor = colorWell.color
        } else if sender === widthSlider {
            settings.setAnnotationStrokeWidth(widthSlider.doubleValue, for: selectionView.activeTool)
            let width = settings.annotationStrokeWidth(for: selectionView.activeTool)
            selectionView.activeWidth = width
            if widthSlider.doubleValue != width { widthSlider.doubleValue = width }
        }
        window.makeFirstResponder(selectionView)
    }

    private var selectedTextSize: EditorTextSize {
        EditorTextSize(rawValue: textSizeControl.selectedSegment) ?? .medium
    }

    @objc private func textSizeChanged() {
        settings.annotationTextSize = selectedTextSize
        window.makeFirstResponder(selectionView)
    }

    @objc private func noAction() {}
    @objc private func recognizeText() { completeCapture(action: .recognizeText) }
    @objc private func pinImage() { completeCapture(action: .pin) }
    @objc private func saveImage() { completeCapture(action: .save) }
    @objc private func finishSelection() { completeCapture(action: .finish) }
    @objc private func cancelSelection() { cancelCapture() }
}

final class RegionSelectionView: NSView {
    private enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isHorizontalEdge: Bool { self == .left || self == .right }
        var isVerticalEdge: Bool { self == .top || self == .bottom }
    }

    private enum DragOperation {
        case creating
        case moving
        case resizing(ResizeHandle)
        case annotating
    }

    var onSelectionChanged: ((CGRect?) -> Void)?
    var onSelectionCommitted: (() -> Void)?
    var onToolGesture: ((EditorTool, EditorInitialGesture) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    var activeTool: EditorTool = .rectangle {
        didSet {
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var activeColor: NSColor = .systemRed
    var activeWidth: CGFloat = 4
    private(set) var isTemporarilyMoving = false
    private var effectiveTool: EditorTool { isTemporarilyMoving ? .move : activeTool }

    func setTemporaryMove(_ moving: Bool) {
        guard moving != isTemporarilyMoving else { return }
        isTemporarilyMoving = moving
        window?.invalidateCursorRects(for: self)
        (effectiveTool == .move ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !isBackdropMode, dragOperation == nil, let selectionRect else { return }
        let origin = CGPoint(
            x: min(max(bounds.minX, selectionRect.minX + dx), max(bounds.minX, bounds.maxX - selectionRect.width)),
            y: min(max(bounds.minY, selectionRect.minY + dy), max(bounds.minY, bounds.maxY - selectionRect.height))
        )
        let next = CGRect(origin: origin, size: selectionRect.size)
        guard next != selectionRect else { return }
        self.selectionRect = next
        invalidateDisplay(selectionRect.insetBy(dx: -12, dy: -12))
        invalidateDisplay(next.insetBy(dx: -12, dy: -12))
        refreshOverlayLabels()
        onSelectionChanged?(next)
        window?.invalidateCursorRects(for: self)
    }

    var currentSelection: CGRect? {
        guard let selectionRect else { return nil }
        let selection = selectionRect.integral.intersection(bounds)
        return selection.width >= 1 && selection.height >= 1 ? selection : nil
    }

    var isAdjustingSelection: Bool {
        switch dragOperation {
        case .moving?, .resizing?: return true
        default: return false
        }
    }

    private let windowCandidates: [CGRect]
    private let frozenDisplayImage: NSImage
    private let safeInsets: NSEdgeInsets
    private let hintView = CaptureGlassLabelView(text: "")
    private let sizeBadgeView = CaptureGlassLabelView(
        text: "",
        font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        horizontalPadding: 9,
        verticalPadding: 5
    )
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var hoveredWindow: CGRect?
    private var snappedWindow: CGRect?
    private var selectionRect: CGRect?
    private var isFreeformDrag = false
    private var dragOperation: DragOperation?
    private var dragOriginPoint: CGPoint?
    private var dragOriginRect: CGRect?
    private var annotationTool: EditorTool?
    private var annotationStart: CGPoint?
    private var annotationCurrent: CGPoint?
    private var annotationPoints: [CGPoint] = []
    private var trackingArea: NSTrackingArea?
    private var isBackdropMode = false
    private var pointerNearBoundary = false

    private let minimumSelectionSize: CGFloat = 16
    private let resizeHandleHitSize: CGFloat = 18

    init(
        windowCandidates: [CGRect],
        frozenDisplay: CapturedImage,
        safeInsets: NSEdgeInsets = .init()
    ) {
        self.windowCandidates = windowCandidates
        frozenDisplayImage = NSImage(
            cgImage: frozenDisplay.cgImage,
            size: frozenDisplay.pointSize
        )
        self.safeInsets = safeInsets
        super.init(frame: .zero)
        hintView.text = windowCandidates.isEmpty
            ? "拖动框选 · Esc 取消"
            : "单击选窗口 · 拖动框选 · Esc 取消"
        hintView.isHidden = true
        sizeBadgeView.isHidden = true
        addSubview(hintView)
        addSubview(sizeBadgeView)
        refreshOverlayLabels()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        refreshOverlayLabels()
    }

    func prepareInitialHover(at windowPoint: CGPoint) {
        let point = convert(windowPoint, from: nil)
        hoveredWindow = bounds.contains(point) ? windowCandidate(at: point) : nil
        refreshOverlayLabels()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutOverlayLabels()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let selectionRect else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }

        addCursorRect(
            selectionRect.insetBy(dx: 8, dy: 8),
            cursor: effectiveTool == .move ? .openHand : .crosshair
        )
        for (handle, center) in resizeHandleCenters(for: selectionRect) {
            addCursorRect(handleHitRect(around: center), cursor: cursor(for: handle))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The overlay renders the single frame captured before it appeared.
        // AppKit maps its native Retina pixels onto the matching point grid;
        // the final image is cropped from the original CGImage, not this view.
        frozenDisplayImage.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: frozenDisplayImage.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        if isBackdropMode {
            // Editing owns the only bright image and selection chrome. Keep
            // this immutable full-screen frame uniformly dimmed underneath it;
            // moving a second cutout behind a native window would leave its
            // previous bright edge visible until AppKit repaints the backdrop.
            NSColor.black.withAlphaComponent(0.34).setFill()
            bounds.fill()
            return
        }
        guard let selection = displayedSelectionRect, selection.width > 1, selection.height > 1 else {
            NSColor.black.withAlphaComponent(0.34).setFill()
            bounds.fill()
            return
        }

        NSColor.black.withAlphaComponent(0.34).setFill()
        let dimmingPath = NSBezierPath(rect: bounds)
        dimmingPath.appendRect(selection)
        dimmingPath.windingRule = .evenOdd
        dimmingPath.fill()

        drawSelectionBorder(around: selection)
        if selectionRect != nil {
            drawResizeHandles(around: selection)
        }

        drawAnnotationDraft()
    }

    func enterBackdropMode() {
        isBackdropMode = true
        resetAnnotationGesture()
        refreshOverlayLabels()
        needsDisplay = true
    }

    func updateBackdropSelection(_ rect: CGRect) {
        guard isBackdropMode else { return }
        // Retain the geometry interface for the coordinator, but the editing
        // backdrop no longer contains a moving aperture or border to repaint.
        selectionRect = rect.standardized.integral.intersection(bounds)
    }

    private func refreshOverlayLabels() {
        if isBackdropMode {
            hintView.isHidden = true
            sizeBadgeView.isHidden = true
            return
        }
        hintView.isHidden = selectionRect != nil || startPoint != nil
        if let selection = displayedSelectionRect,
           selection.width > 1, selection.height > 1,
           selectionRect == nil || isAdjustingSelection {
            let text = "\(Int(selection.width)) × \(Int(selection.height))"
            if sizeBadgeView.text != text { sizeBadgeView.text = text }
            sizeBadgeView.isHidden = false
        } else {
            sizeBadgeView.isHidden = true
        }
        layoutOverlayLabels()
    }

    private func layoutOverlayLabels() {
        guard !isBackdropMode, bounds.width > 0, bounds.height > 0 else { return }
        let safeLeft = bounds.minX + safeInsets.left + 8
        let safeRight = bounds.maxX - safeInsets.right - 8
        let safeTop = bounds.minY + safeInsets.top + 8
        let safeBottom = bounds.maxY - safeInsets.bottom - 8
        if !hintView.isHidden {
            let natural = hintView.intrinsicContentSize
            let size = CGSize(width: min(ceil(natural.width), max(1, safeRight - safeLeft)), height: ceil(natural.height))
            let frame = CGRect(
                x: min(max(bounds.midX - size.width / 2, safeLeft), max(safeLeft, safeRight - size.width)),
                y: safeTop + 4,
                width: size.width,
                height: size.height
            )
            if hintView.frame != frame { hintView.frame = frame }
        }
        guard !sizeBadgeView.isHidden, let selection = displayedSelectionRect else { return }
        let natural = sizeBadgeView.intrinsicContentSize
        let size = CGSize(width: min(ceil(natural.width), max(1, safeRight - safeLeft)), height: ceil(natural.height))
        var y = selection.minY - size.height - 6
        if y < safeTop { y = selection.minY + 6 }
        var frame = CGRect(
            x: min(max(selection.minX, safeLeft), max(safeLeft, safeRight - size.width)),
            y: min(max(y, safeTop), max(safeTop, safeBottom - size.height)),
            width: size.width,
            height: size.height
        )
        if !hintView.isHidden, frame.intersects(hintView.frame.insetBy(dx: -6, dy: -6)) {
            frame.origin.y = min(hintView.frame.maxY + 6, max(safeTop, safeBottom - size.height))
        }
        if sizeBadgeView.frame != frame { sizeBadgeView.frame = frame }
    }

    private func drawSelectionBorder(around selection: CGRect) {
        let borderRect = selection.insetBy(dx: 0.5, dy: 0.5)
        guard borderRect.width > 0, borderRect.height > 0 else { return }
        let radius = min(CaptureAppearance.selectionCornerRadius, min(borderRect.width, borderRect.height) / 2)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: radius, yRadius: radius)
        CaptureAppearance.selectionDarkOutline.setStroke()
        border.lineWidth = 1
        border.stroke()
        let innerRect = borderRect.insetBy(dx: 0.75, dy: 0.75)
        guard innerRect.width > 0, innerRect.height > 0 else { return }
        let innerRadius = min(CaptureAppearance.selectionCornerRadius, min(innerRect.width, innerRect.height) / 2)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)
        CaptureAppearance.selectionLightOutline.setStroke()
        inner.lineWidth = 0.75
        inner.stroke()
    }

    private func drawResizeHandles(around selection: CGRect) {
        let accent = CaptureAppearance.selectionDarkOutline
        let emphasized = pointerNearBoundary || isAdjustingSelection
        for (handle, center) in resizeHandleCenters(for: selection) {
            let diameter: CGFloat = emphasized ? CaptureAppearance.handleDiameter : (handle.isHorizontalEdge || handle.isVerticalEdge ? 4 : 5)
            let rect = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            shadow.set()
            NSColor.white.withAlphaComponent(emphasized ? 1 : 0.82).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.restoreGraphicsState()

            accent.withAlphaComponent(emphasized ? 0.95 : 0.65).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private func drawAnnotationDraft() {
        guard let tool = annotationTool,
              let start = annotationStart,
              let end = annotationCurrent else { return }

        let path = NSBezierPath()
        path.lineWidth = max(1, activeWidth)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        activeColor.withAlphaComponent(0.96).setStroke()

        switch tool {
        case .line:
            path.move(to: start)
            path.line(to: end)
            path.stroke()
        case .arrow:
            path.move(to: start)
            path.line(to: end)
            path.stroke()
            drawArrowHead(from: start, to: end)
        case .rectangle:
            path.appendRect(normalizedRect(from: start, to: end))
            path.stroke()
        case .ellipse:
            path.appendOval(in: normalizedRect(from: start, to: end))
            path.stroke()
        case .pen:
            guard annotationPoints.count > 1 else { return }
            path.move(to: annotationPoints[0])
            annotationPoints.dropFirst().forEach { path.line(to: $0) }
            path.stroke()
        case .mosaic:
            activeColor.withAlphaComponent(0.20).setFill()
            normalizedRect(from: start, to: end).fill()
            path.appendRect(normalizedRect(from: start, to: end))
            path.stroke()
        case .crop:
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.appendRect(normalizedRect(from: start, to: end))
            path.stroke()
        case .text, .move:
            break
        }
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let direction = atan2(dy, dx)
        let headLength = min(24, max(11, length * 0.18 + activeWidth))
        let spread: CGFloat = .pi / 7
        let head = NSBezierPath()
        head.lineWidth = max(1, activeWidth)
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.move(to: CGPoint(
            x: end.x - headLength * cos(direction - spread),
            y: end.y - headLength * sin(direction - spread)
        ))
        head.line(to: end)
        head.line(to: CGPoint(
            x: end.x - headLength * cos(direction + spread),
            y: end.y - headLength * sin(direction + spread)
        ))
        head.stroke()
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func invalidateDisplay(_ rect: CGRect) {
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        setNeedsDisplay(clipped)
    }

    private func annotationDraftInvalidationRects() -> [CGRect] {
        guard let tool = annotationTool,
              let start = annotationStart,
              let end = annotationCurrent else { return [] }
        let padding = max(5, activeWidth + 3)
        if tool == .rectangle || tool == .crop {
            let rect = normalizedRect(from: start, to: end)
            let thickness = padding * 2
            return [
                CGRect(x: rect.minX - padding, y: rect.minY - padding, width: rect.width + padding * 2, height: thickness),
                CGRect(x: rect.minX - padding, y: rect.maxY - padding, width: rect.width + padding * 2, height: thickness),
                CGRect(x: rect.minX - padding, y: rect.minY + padding, width: thickness, height: max(0, rect.height - padding * 2)),
                CGRect(x: rect.maxX - padding, y: rect.minY + padding, width: thickness, height: max(0, rect.height - padding * 2))
            ]
        }
        if tool == .pen, let first = annotationPoints.first {
            let rect = annotationPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
            return [rect.insetBy(dx: -padding, dy: -padding)]
        }
        return [normalizedRect(from: start, to: end).insetBy(dx: -padding, dy: -padding)]
    }

    private var freeformSelectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    private var displayedSelectionRect: CGRect? {
        if let selectionRect { return selectionRect }
        if isFreeformDrag { return freeformSelectionRect }
        return snappedWindow ?? hoveredWindow
    }

    private var isShowingWindowCandidate: Bool {
        selectionRect == nil && !isFreeformDrag && displayedSelectionRect != nil
    }

    private func resizeHandleCenters(for rect: CGRect) -> [(ResizeHandle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY))
        ]
    }

    private func handleHitRect(around center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - resizeHandleHitSize / 2,
            y: center.y - resizeHandleHitSize / 2,
            width: resizeHandleHitSize,
            height: resizeHandleHitSize
        )
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        if let handle = resizeHandleCenters(for: rect).first(where: { _, center in
            handleHitRect(around: center).contains(point)
        })?.0 {
            return handle
        }

        let hitSlop = resizeHandleHitSize / 2
        if abs(point.x - rect.minX) <= hitSlop,
           point.y >= rect.minY,
           point.y <= rect.maxY { return .left }
        if abs(point.x - rect.maxX) <= hitSlop,
           point.y >= rect.minY,
           point.y <= rect.maxY { return .right }
        if abs(point.y - rect.minY) <= hitSlop,
           point.x >= rect.minX,
           point.x <= rect.maxX { return .top }
        if abs(point.y - rect.maxY) <= hitSlop,
           point.x >= rect.minX,
           point.x <= rect.maxX { return .bottom }
        return nil
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        if handle.isHorizontalEdge { return .resizeLeftRight }
        if handle.isVerticalEdge { return .resizeUpDown }
        return .crosshair
    }

    private func windowCandidate(at point: CGPoint) -> CGRect? {
        windowCandidates.first { $0.contains(point) }
    }

    private func pointInBounds(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragOperation == nil else { return }
        let point = pointInBounds(from: event)
        if let selectionRect {
            let near = resizeHandle(at: point, in: selectionRect) != nil
            if near != pointerNearBoundary {
                pointerNearBoundary = near
                invalidateSelectionChrome(selectionRect)
            }
            if let handle = resizeHandle(at: point, in: selectionRect) {
                cursor(for: handle).set()
            } else if selectionRect.contains(point) {
                (effectiveTool == .move ? NSCursor.openHand : NSCursor.crosshair).set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            let previous = hoveredWindow
            hoveredWindow = windowCandidate(at: point)
            NSCursor.crosshair.set()
            if previous != hoveredWindow {
                refreshOverlayLabels()
                needsDisplay = true
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard pointerNearBoundary else { return }
        pointerNearBoundary = false
        if let selectionRect { invalidateSelectionChrome(selectionRect) }
    }

    private func invalidateSelectionChrome(_ rect: CGRect) {
        let padding: CGFloat = 10
        let thickness = padding * 2
        for edge in [
            CGRect(x: rect.minX - padding, y: rect.minY - padding, width: rect.width + thickness, height: thickness),
            CGRect(x: rect.minX - padding, y: rect.maxY - padding, width: rect.width + thickness, height: thickness),
            CGRect(x: rect.minX - padding, y: rect.minY, width: thickness, height: rect.height),
            CGRect(x: rect.maxX - padding, y: rect.minY, width: thickness, height: rect.height)
        ] { invalidateDisplay(edge) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = pointInBounds(from: event)

        if let selectionRect {
            if let handle = resizeHandle(at: point, in: selectionRect) {
                dragOperation = .resizing(handle)
                dragOriginPoint = point
                dragOriginRect = selectionRect
                cursor(for: handle).set()
                refreshOverlayLabels()
                return
            }
            if selectionRect.contains(point) {
                if effectiveTool == .move {
                    dragOperation = .moving
                    dragOriginPoint = point
                    dragOriginRect = selectionRect
                    NSCursor.closedHand.set()
                } else {
                    dragOperation = .annotating
                    annotationTool = effectiveTool
                    annotationStart = point
                    annotationCurrent = point
                    annotationPoints = [point]
                    NSCursor.crosshair.set()
                }
                refreshOverlayLabels()
                return
            }
        }

        self.selectionRect = nil
        onSelectionChanged?(nil)
        startPoint = point
        currentPoint = point
        snappedWindow = windowCandidate(at: point)
        isFreeformDrag = false
        dragOperation = .creating
        dragOriginPoint = nil
        dragOriginRect = nil
        refreshOverlayLabels()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let previousDraftRects = annotationDraftInvalidationRects()
        let operation = dragOperation
        updateDrag(to: pointInBounds(from: event))
        if case .annotating? = operation {
            previousDraftRects.forEach(invalidateDisplay)
            annotationDraftInvalidationRects().forEach(invalidateDisplay)
        } else if selectionRect != nil {
            onSelectionChanged?(currentSelection)
            needsDisplay = true
        } else {
            needsDisplay = true
        }
        refreshOverlayLabels()
    }

    override func mouseUp(with event: NSEvent) {
        let point = pointInBounds(from: event)

        updateDrag(to: point)

        switch dragOperation {
        case .creating:
            if isFreeformDrag,
               let rect = freeformSelectionRect,
               rect.width >= 4,
               rect.height >= 4 {
                setSelection(rect)
            } else if let rect = snappedWindow ?? hoveredWindow ?? windowCandidate(at: point) {
                setSelection(rect)
            } else {
                resetInteraction()
            }
        case .moving, .resizing:
            finishAdjustment()
        case .annotating:
            finishAnnotationGesture()
        case nil:
            break
        }
    }

    private func updateDrag(to point: CGPoint) {
        switch dragOperation {
        case .creating:
            currentPoint = point
            if let startPoint,
               hypot(point.x - startPoint.x, point.y - startPoint.y) >= 6 {
                isFreeformDrag = true
                snappedWindow = nil
            }
        case .moving:
            guard let dragOriginPoint, let dragOriginRect else { return }
            let proposedX = dragOriginRect.minX + point.x - dragOriginPoint.x
            let proposedY = dragOriginRect.minY + point.y - dragOriginPoint.y
            selectionRect = CGRect(
                x: min(max(bounds.minX, proposedX), bounds.maxX - dragOriginRect.width),
                y: min(max(bounds.minY, proposedY), bounds.maxY - dragOriginRect.height),
                width: dragOriginRect.width,
                height: dragOriginRect.height
            )
        case let .resizing(handle):
            guard let dragOriginRect else { return }
            selectionRect = resizedRect(dragOriginRect, moving: handle, to: point)
        case .annotating:
            annotationCurrent = point
            if annotationTool == .pen,
               annotationPoints.last.map({ hypot(point.x - $0.x, point.y - $0.y) >= 0.75 }) ?? true {
                annotationPoints.append(point)
            }
        case nil:
            break
        }
    }

    private func finishAnnotationGesture() {
        let draftRects = annotationDraftInvalidationRects()
        guard let selectionRect,
              let tool = annotationTool,
              let start = annotationStart,
              let end = annotationCurrent else {
            resetAnnotationGesture()
            draftRects.forEach(invalidateDisplay)
            return
        }

        let localStart = editorPoint(start, inside: selectionRect)
        let localEnd = editorPoint(end, inside: selectionRect)
        let gesture: EditorInitialGesture?
        switch tool {
        case .text:
            gesture = .tap(localStart)
        case .pen:
            let points = annotationPoints.map { editorPoint($0, inside: selectionRect) }
            let distance = zip(points, points.dropFirst()).reduce(CGFloat.zero) { total, pair in
                total + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            }
            gesture = points.count > 1 && distance >= 3 ? .freehand(points) : nil
        case .line, .arrow, .rectangle, .ellipse, .mosaic, .crop:
            gesture = hypot(localEnd.x - localStart.x, localEnd.y - localStart.y) >= 3
                ? .drag(from: localStart, to: localEnd)
                : nil
        case .move:
            gesture = nil
        }

        if let gesture, onToolGesture != nil {
            // Keep the last draft frame visible during the safe handoff. It is
            // replaced only after the fully configured editor is already on
            // screen, so the first rectangle/pen stroke does not blink away.
            onToolGesture?(tool, gesture)
            return
        }
        resetAnnotationGesture()
        draftRects.forEach(invalidateDisplay)
    }

    private func editorPoint(_ point: CGPoint, inside selection: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x - selection.minX), selection.width),
            y: min(max(0, point.y - selection.minY), selection.height)
        )
    }

    private func resetAnnotationGesture() {
        dragOperation = nil
        annotationTool = nil
        annotationStart = nil
        annotationCurrent = nil
        annotationPoints.removeAll(keepingCapacity: true)
    }

    private func resizedRect(_ original: CGRect, moving handle: ResizeHandle, to point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        if handle.movesLeftEdge {
            minX = min(max(bounds.minX, point.x), maxX - minimumSelectionSize)
        }
        if handle.movesRightEdge {
            maxX = max(min(bounds.maxX, point.x), minX + minimumSelectionSize)
        }
        if handle.movesTopEdge {
            minY = min(max(bounds.minY, point.y), maxY - minimumSelectionSize)
        }
        if handle.movesBottomEdge {
            maxY = max(min(bounds.maxY, point.y), minY + minimumSelectionSize)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func setSelection(_ rect: CGRect) {
        let selection = rect.standardized.integral.intersection(bounds)
        guard selection.width >= 1, selection.height >= 1 else {
            resetInteraction()
            return
        }
        selectionRect = selection
        finishAdjustment()
        // Selection changes during resizing are deliberately separate from
        // this one-time commit at the end of the first click/freeform drag.
        onSelectionCommitted?()
    }

    private func finishAdjustment() {
        dragOperation = nil
        dragOriginPoint = nil
        dragOriginRect = nil
        startPoint = nil
        currentPoint = nil
        snappedWindow = nil
        hoveredWindow = nil
        isFreeformDrag = false
        window?.invalidateCursorRects(for: self)
        (effectiveTool == .move ? NSCursor.openHand : NSCursor.crosshair).set()
        refreshOverlayLabels()
        onSelectionChanged?(currentSelection)
        needsDisplay = true
    }

    private func resetInteraction() {
        selectionRect = nil
        startPoint = nil
        currentPoint = nil
        snappedWindow = nil
        dragOperation = nil
        dragOriginPoint = nil
        dragOriginRect = nil
        isFreeformDrag = false
        window?.invalidateCursorRects(for: self)
        NSCursor.crosshair.set()
        refreshOverlayLabels()
        onSelectionChanged?(nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if (event.keyCode == 36 || event.keyCode == 76), selectionRect != nil {
            onConfirm?()
        } else {
            super.keyDown(with: event)
        }
    }
}
