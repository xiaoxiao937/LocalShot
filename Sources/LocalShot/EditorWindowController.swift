import AppKit
import UniformTypeIdentifiers

enum EditorTool: Int, CaseIterable {
    case move, line, arrow, rectangle, ellipse, pen, text, mosaic, crop

    static let toolbarTools: [EditorTool] = [
        .move, .text, .arrow, .rectangle, .pen, .mosaic, .crop
    ]

    var title: String {
        switch self {
        case .move: return "移动"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .crop: return "裁剪"
        }
    }

    var symbolName: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil"
        case .text: return "character.textbox"
        case .mosaic: return "square.grid.3x3.fill"
        case .crop: return "crop"
        }
    }
}

enum EditorTextSize: Int, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: return 18
        case .medium: return 28
        case .large: return 40
        }
    }

    static func nearest(to pointSize: CGFloat) -> EditorTextSize {
        allCases.min { abs($0.pointSize - pointSize) < abs($1.pointSize - pointSize) } ?? .medium
    }
}

enum TextLayoutMode: Equatable {
    case auto, fixed
}

enum Annotation: Equatable {
    case line(CGPoint, CGPoint, NSColor, CGFloat, Bool)
    case rectangle(CGRect, NSColor, CGFloat)
    case ellipse(CGRect, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat, CGFloat, TextLayoutMode)
    case mosaic(CGRect)
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onLongScreenshot: ((CapturedImage) throws -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    var onBackdropDismissRequest: (() -> Void)?
    var onPresentationActiveChange: ((Bool) -> Void)?
    var isPinned: Bool { !canvas.isEditing }
    private let settings: SettingsStore
    private let canvas: EditorCanvasView
    private let toolbarPanel: NSPanel
    private let colorWell = CaptureColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private let textSizeControl = NSSegmentedControl(
        labels: EditorTextSize.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private lazy var styleControls = CaptureStyleControlsView(
        colorWell: colorWell,
        widthSlider: widthSlider,
        textSizeControl: textSizeControl
    )
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var closeKeyMonitor: Any?
    private var textResultController: TextRecognitionWindowController?
    private var textRecognitionOperation: TextRecognitionService.Operation?
    private var textRecognitionGeneration = 0
    private var textRecognitionProgressView: NSVisualEffectView?
    private var textRecognitionSpinner: NSProgressIndicator?
    private var imageExportTask: Task<Void, Never>?
    private var imageExportWorkerCancellation: (() -> Void)?
    private var imageExportGeneration = 0
    private var isClosing = false
    private var savePanel: NSSavePanel?
    private var feedbackPresentationID: Int?
    private var toolbarStack: NSStackView?
    private var toolbarHost: NSView?
    private var toolbarNaturalSize: CGSize = .zero
    private var toolbarGroups: [NSView] = []
    private var toolbarIsCompact = false
    private var toolbarAvailableWidth: CGFloat?
    private var usesFrozenBackdrop = false
    private enum ToolbarPlacement { case below, above, inside }
    private var toolbarPlacement: ToolbarPlacement?
    private var isCanvasInteracting = false
    private var toolbarNeedsSettlement = false
    private var isApplyingViewportFrame = false
    private let captureSourceTopLeft: CGPoint?
    private var pinnedNativeSize: CGSize?
    private var pinnedScale: CGFloat = 1
    private lazy var pinCloseButton: NSButton = {
        let image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "关闭贴图"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        let button = PinnedImageCloseButton(image: image ?? NSImage(), target: self, action: #selector(closeEditor))
        button.bezelStyle = .circular
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = "关闭贴图（Esc 或 ⌘W）"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    init(image: CapturedImage, settings: SettingsStore) {
        self.settings = settings
        let initialViewportOrigin = image.selectionRect?.origin ?? .zero
        captureSourceTopLeft = image.screenRect.map {
            CGPoint(x: $0.minX - initialViewportOrigin.x, y: $0.maxY + initialViewportOrigin.y)
        }
        canvas = EditorCanvasView(image: image)
        let window = EditorOverlayWindow(
            contentRect: NSRect(origin: image.screenRect?.origin ?? .zero, size: image.pointSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        toolbarPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: CaptureAppearance.toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        canvas.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: image.pointSize)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas

        if let screenRect = image.screenRect {
            window.setFrame(screenRect, display: false)
        } else {
            window.center()
        }

        toolbarPanel.level = .floating
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.hasShadow = true
        toolbarPanel.becomesKeyOnlyIfNeeded = true
        buildUI()
        canvas.onSizeChange = { [weak self] size in self?.resizeCanvas(to: size) }
        let initialFrame = image.screenRect ?? window.frame
        let sourceScreenTopLeft = CGPoint(
            x: initialFrame.minX - initialViewportOrigin.x,
            y: initialFrame.maxY + initialViewportOrigin.y
        )
        canvas.onViewportChange = { [weak self] _, newRect in
            guard let self, !self.isClosing, let window = self.window else { return }
            // Do not accumulate deltas on a window frame AppKit may round.
            // Every crop and its window use the same frozen-screen origin.
            let frame = CGRect(
                x: sourceScreenTopLeft.x + newRect.minX,
                y: sourceScreenTopLeft.y - newRect.maxY,
                width: newRect.width,
                height: newRect.height
            )
            self.isApplyingViewportFrame = true
            if window.frame != frame { window.setFrame(frame, display: false, animate: false) }
            self.isApplyingViewportFrame = false
            self.canvas.displayIfNeeded()
            if self.isCanvasInteracting { self.toolbarNeedsSettlement = true }
            self.positionToolbar()
            self.onFrameChange?(window.frame)
        }
        canvas.onToolChangeRequest = { [weak self] tool in self?.setTool(tool) }
        canvas.onTextSizeChangeRequest = { [weak self] size in
            guard let self else { return }
            if self.textSizeControl.selectedSegment != size.rawValue {
                self.textSizeControl.selectedSegment = size.rawValue
            }
            self.refreshStyleContext()
        }
        canvas.onSelectionToolChange = { [weak self] _ in
            self?.refreshStyleContext()
        }
        canvas.onInteractionChange = { [weak self] isInteracting in
            guard let self, !self.isClosing else { return }
            self.isCanvasInteracting = isInteracting
            // A stroke inside an unchanged crop has no effect on toolbar
            // geometry. Only settle placement after a real viewport move.
            if !isInteracting, self.toolbarNeedsSettlement {
                self.toolbarNeedsSettlement = false
                self.positionToolbar()
            }
        }
        canvas.onHistoryChange = { [weak self] in self?.refreshHistoryControls() }
        canvas.onPinnedZoom = { [weak self] factor in self?.zoomPinnedImage(by: factor) }
        canvas.onPinnedReset = { [weak self] in self?.resetPinnedImageSize() }
        refreshHistoryControls()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        window?.displayIfNeeded()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        installCloseKeyMonitor()
        positionToolbar()
        toolbarPanel.orderFront(nil)
        if toolbarPanel.parent == nil {
            window?.addChildWindow(toolbarPanel, ordered: .above)
        }
        if canvas.isEnteringText {
            canvas.focusInlineText()
        } else {
            window?.makeFirstResponder(canvas)
        }
        if let frame = window?.frame { onFrameChange?(frame) }
    }

    func prepareForFrozenBackdrop() {
        usesFrozenBackdrop = true
        window?.level = .statusBar
        toolbarPanel.level = .statusBar
    }

    func perform(_ action: RegionCaptureAction) {
        switch action {
        case let .edit(tool, color, width, textSize, gesture):
            setTool(tool)
            // The region toolbar already saved user preferences. Transfer
            // this gesture's actual style without writing another tool's key.
            canvas.strokeColor = color
            canvas.strokeWidth = width
            canvas.applyTextSize(textSize, updateSelection: false)
            refreshStyleContext()
            if let gesture {
                canvas.applyInitialGesture(gesture, for: tool)
            }
        case .recognizeText:
            recognizeText()
        case .pin:
            pinImage()
        case .save:
            saveImage()
        case .finish:
            finishEditing()
        }
    }

    private func buildUI() {
        let toolGroup = toolbarGroup()
        for (index, tool) in EditorTool.toolbarTools.enumerated() {
            let button = iconButton(symbol: tool.symbolName, tip: "\(index + 1) · \(tool.title)", action: #selector(selectTool(_:)))
            button.tag = tool.rawValue
            button.setButtonType(.toggle)
            button.state = tool == .move ? .on : .off
            toolButtons.append(button)
            toolGroup.addArrangedSubview(button)
        }

        let styleGroup = styleControls
        colorWell.color = settings.annotationColor
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.onColorChange = { [weak self] color in self?.applyColorSelection(color) }
        colorWell.toolTip = "标注颜色"
        colorWell.colorWellStyle = .minimal
        colorWell.onPaletteClose = { [weak self] in
            self?.restoreFocusAfterPalette()
        }
        widthSlider.doubleValue = settings.annotationStrokeWidth(for: settings.defaultTool)
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.isContinuous = false
        widthSlider.toolTip = "线条粗细"
        textSizeControl.selectedSegment = settings.annotationTextSize.rawValue
        textSizeControl.target = self
        textSizeControl.action = #selector(textSizeChanged)
        textSizeControl.toolTip = "文字大小：小 / 中 / 大"

        let editActionGroup = toolbarGroup()
        let undoButton = iconButton(symbol: "arrow.uturn.backward", tip: "撤销（⌘Z）", action: #selector(undo))
        let redoButton = iconButton(symbol: "arrow.uturn.forward", tip: "重做（⇧⌘Z）", action: #selector(redo))
        self.undoButton = undoButton
        self.redoButton = redoButton
        editActionGroup.addArrangedSubview(undoButton)
        editActionGroup.addArrangedSubview(redoButton)
        editActionGroup.addArrangedSubview(iconButton(symbol: "text.viewfinder", tip: "提取文字", action: #selector(recognizeText)))
        editActionGroup.addArrangedSubview(iconButton(symbol: "pin", tip: "贴图", action: #selector(pinImage)))
        if captureSourceTopLeft != nil {
            editActionGroup.addArrangedSubview(iconButton(symbol: "arrow.down.to.line", tip: "长截图", action: #selector(startLongScreenshot)))
        }

        let completionGroup = toolbarGroup()
        completionGroup.addArrangedSubview(iconButton(symbol: "square.and.arrow.down", tip: "下载 PNG", action: #selector(saveImage)))
        let finish = iconButton(symbol: "checkmark", tip: "复制并完成", action: #selector(finishEditing))
        CaptureAppearance.styleButton(finish, primary: true)
        completionGroup.addArrangedSubview(finish)
        let cancel = iconButton(symbol: "xmark", tip: "取消", action: #selector(closeEditor))
        cancel.contentTintColor = .secondaryLabelColor
        completionGroup.addArrangedSubview(cancel)

        let toolbar = NSStackView(views: [
            toolGroup,
            toolbarSeparator(),
            styleGroup,
            toolbarSeparator(),
            editActionGroup,
            toolbarSeparator(),
            completionGroup
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = CaptureAppearance.toolbarSpacing

        toolbar.layoutSubtreeIfNeeded()
        let fitting = toolbar.fittingSize
        let contentSize = CGSize(width: ceil(fitting.width) + CaptureAppearance.toolbarHorizontalPadding * 2, height: CaptureAppearance.toolbarHeight)
        toolbarPanel.setContentSize(contentSize)

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
        toolbarPanel.contentView = toolbarBackground(frame: NSRect(origin: .zero, size: contentSize), host: host)
        toolbarStack = toolbar
        toolbarHost = host
        toolbarNaturalSize = contentSize
        toolbarGroups = [toolGroup, styleGroup, editActionGroup, completionGroup]
        canvas.strokeColor = settings.annotationColor
        canvas.strokeWidth = settings.annotationStrokeWidth(for: settings.defaultTool)
        canvas.applyTextSize(settings.annotationTextSize, updateSelection: false)
        setTool(settings.defaultTool)
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
        CaptureAppearance.styleButton(button)
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = EditorTool(rawValue: sender.tag) else { return }
        setTool(tool)
    }

    private func setTool(_ tool: EditorTool) {
        guard canvas.isEditing, !isClosing else { return }
        canvas.endKeyboardNudgeGroup()
        canvas.tool = tool
        canvas.strokeWidth = settings.annotationStrokeWidth(for: tool)
        toolButtons.forEach {
            let state: NSControl.StateValue = ($0.tag == tool.rawValue) ? .on : .off
            if $0.state != state { $0.state = state }
        }
        refreshStyleContext()
    }

    private func refreshStyleContext() {
        let selectionIsContext = canvas.isEnteringText
            || (canvas.tool == .move && canvas.selectedAnnotationTool != nil)
        let color = selectionIsContext ? (canvas.selectedAnnotationColor ?? canvas.strokeColor) : canvas.strokeColor
        if !colorWell.color.isEqual(color) { colorWell.color = color }
        let width = Double(selectionIsContext ? (canvas.selectedAnnotationStrokeWidth ?? canvas.strokeWidth) : canvas.strokeWidth)
        if widthSlider.doubleValue != width { widthSlider.doubleValue = width }
        let fontSize = selectionIsContext ? (canvas.selectedAnnotationFontSize ?? canvas.textFontSize) : canvas.textFontSize
        let segment = EditorTextSize.nearest(to: fontSize).rawValue
        if textSizeControl.selectedSegment != segment { textSizeControl.selectedSegment = segment }
        styleControls.update(tool: canvas.tool, selectedTool: canvas.selectedAnnotationTool)
    }

    @objc private func styleChanged(_ sender: NSControl) {
        if sender === colorWell {
            applyColorSelection(colorWell.color)
            return
        }
        canvas.endKeyboardNudgeGroup()
        if canvas.tool == .move, canvas.selectedAnnotationTool != nil {
            if sender === widthSlider { canvas.applySelectedStyle(strokeWidth: widthSlider.doubleValue) }
        } else if sender === widthSlider {
            settings.setAnnotationStrokeWidth(widthSlider.doubleValue, for: canvas.tool)
            canvas.strokeWidth = settings.annotationStrokeWidth(for: canvas.tool)
        }
    }

    private func applyColorSelection(_ color: NSColor) {
        guard !isClosing, canvas.isEditing else { return }
        canvas.endKeyboardNudgeGroup()
        // A chosen color also becomes the next annotation's color, even when
        // the current selection is existing text rather than a drawing tool.
        canvas.strokeColor = color
        settings.annotationColor = color
        if canvas.tool == .move || canvas.tool == .text || canvas.isEnteringText {
            canvas.applySelectedStyle(color: color)
        }
        refreshStyleContext()
    }

    private func restoreFocusAfterPalette() {
        // A transient palette can close because the user chose Settings or
        // OCR. Let that focus transition finish before considering a return.
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive, !self.isClosing,
                  self.canvas.isEditing, let window = self.window,
                  window.isVisible else { return }
            if let keyWindow = NSApp.keyWindow,
               keyWindow !== window, keyWindow !== self.toolbarPanel { return }
            window.makeKeyAndOrderFront(nil)
            if self.canvas.isEnteringText { self.canvas.focusInlineText() }
            else { window.makeFirstResponder(self.canvas) }
        }
    }

    @objc private func textSizeChanged() {
        let size = EditorTextSize(rawValue: textSizeControl.selectedSegment) ?? .medium
        canvas.applyTextSize(size, updateSelection: true)
        settings.annotationTextSize = size
    }

    @objc private func undo() { canvas.undoLast() }
    @objc private func redo() { canvas.redoLast() }

    private func refreshHistoryControls() {
        func update(_ button: NSButton?, enabled: Bool, title: String) {
            guard let button else { return }
            if button.isEnabled != enabled { button.isEnabled = enabled }
            if button.toolTip != title {
                button.toolTip = title
                button.setAccessibilityLabel(title)
            }
        }
        let canUndo = canvas.canUndo
        let canRedo = canvas.canRedo
        update(undoButton, enabled: canUndo, title: "\(canUndo ? canvas.undoTitle : "没有可撤销的操作")（⌘Z）")
        update(redoButton, enabled: canRedo, title: "\(canRedo ? canvas.redoTitle : "没有可重做的操作")（⇧⌘Z）")
    }

    @objc private func recognizeText() {
        canvas.endKeyboardNudgeGroup()
        guard !isClosing, canvas.isEditing, imageExportTask == nil,
              let image = canvas.flattenedCGImage() else { return }
        cancelTextRecognition()
        textRecognitionGeneration &+= 1
        let generation = textRecognitionGeneration
        showTextRecognitionProgress()
        textRecognitionOperation = TextRecognitionService.shared.recognize(image) { [weak self] result in
            guard let self, self.textRecognitionGeneration == generation else { return }
            self.textRecognitionOperation = nil
            self.hideTextRecognitionProgress()
            switch result {
            case let .success(text):
                guard !text.isEmpty else {
                    self.showFeedback(title: "没有识别到文字", message: "请换一个包含清晰文字的区域再试。")
                    return
                }
                self.presentRecognizedText(text)
            case .failure(is CancellationError):
                break
            case let .failure(error):
                self.showFeedback(title: "文字识别失败", message: error.localizedDescription)
            }
        }
    }

    private func presentRecognizedText(_ text: String) {
        let controller = TextRecognitionWindowController(text: text)
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.textResultController === controller else { return }
            self.textResultController = nil
            if NSApp.isActive, !self.isClosing, self.window?.isVisible == true {
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.canvas)
            }
        }
        textResultController?.close()
        textResultController = controller
        controller.onRetry = { [weak self, weak controller] in
            guard let self, !self.isClosing, NSApp.isActive else { return }
            controller?.close()
            self.window?.makeKeyAndOrderFront(nil)
            self.recognizeText()
        }
        controller.onSizeChange = { [weak self] in self?.positionTextResult() }
        controller.onFocusChange = { [weak self] in self?.textResultFocusChanged() }
        if let window { controller.showAnchored(to: window) }
    }

    private func positionTextResult() {
        guard !isClosing, let window else { return }
        textResultController?.position(relativeTo: window.frame, on: window.screen)
    }

    private func textResultFocusChanged() {
        guard !isClosing, canvas.isEditing else { return }
        if NSApp.isActive, textResultController?.window?.isKeyWindow == true {
            if usesFrozenBackdrop {
                window?.level = .statusBar
                toolbarPanel.level = .statusBar
                textResultController?.window?.level = .statusBar
            }
            onPresentationActiveChange?(true)
            positionToolbar()
            toolbarPanel.orderFront(nil)
        } else {
            deferPresentationSuspension()
        }
    }

    private func showTextRecognitionProgress() {
        guard let contentView = window?.contentView else { return }
        if textRecognitionProgressView == nil {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.translatesAutoresizingMaskIntoConstraints = false

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 18).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let label = NSTextField(labelWithString: "正在识别文字…")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor

            let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTextRecognition))
            cancelButton.bezelStyle = .rounded
            cancelButton.controlSize = .small

            let stack = NSStackView(views: [spinner, label, cancelButton])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            contentView.addSubview(effect)
            NSLayoutConstraint.activate([
                effect.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                effect.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10)
            ])
            textRecognitionProgressView = effect
            textRecognitionSpinner = spinner
        }
        textRecognitionProgressView?.isHidden = false
        textRecognitionSpinner?.startAnimation(nil)
    }

    private func hideTextRecognitionProgress() {
        textRecognitionSpinner?.stopAnimation(nil)
        textRecognitionProgressView?.isHidden = true
    }

    @objc private func cancelTextRecognition() {
        textRecognitionGeneration &+= 1
        textRecognitionOperation?.cancel()
        textRecognitionOperation = nil
        hideTextRecognitionProgress()
    }

    func cancelBackgroundWork() {
        cancelTextRecognition()
        imageExportGeneration &+= 1
        imageExportWorkerCancellation?()
        imageExportWorkerCancellation = nil
        imageExportTask?.cancel()
        imageExportTask = nil
        if let savePanel {
            self.savePanel = nil
            window?.endSheet(savePanel, returnCode: .cancel)
            savePanel.orderOut(nil)
        }
        CopyConfirmationPresenter.shared.dismiss(feedbackPresentationID)
        feedbackPresentationID = nil
    }

    @objc private func pinImage() {
        guard !isClosing, canvas.isEditing, imageExportTask == nil, savePanel == nil else { return }
        guard canvas.freezeForPin() else {
            showFeedback(title: "无法贴图", message: "请重试，或将截图保存为 PNG。")
            return
        }
        cancelTextRecognition()
        textResultController?.close()
        textResultController = nil
        pinnedNativeSize = window?.contentView?.bounds.size
        pinnedScale = 1
        usesFrozenBackdrop = false
        onBackdropDismissRequest?()
        onBackdropDismissRequest = nil
        canvas.layer?.borderWidth = 0
        toolbarPanel.orderOut(nil)
        window?.level = .floating
        window?.isMovableByWindowBackground = true
        if pinCloseButton.superview == nil {
            canvas.addSubview(pinCloseButton)
            NSLayoutConstraint.activate([
                pinCloseButton.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 10),
                pinCloseButton.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -10),
                pinCloseButton.widthAnchor.constraint(equalToConstant: 28),
                pinCloseButton.heightAnchor.constraint(equalToConstant: 28)
            ])
        }
        pinCloseButton.isHidden = false
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        setPinnedScale(1, preservePointer: false)
    }

    private func zoomPinnedImage(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        setPinnedScale(pinnedScale * factor, preservePointer: true)
    }

    private func resetPinnedImageSize() { setPinnedScale(1, preservePointer: false) }

    private func setPinnedScale(_ requestedScale: CGFloat, preservePointer: Bool) {
        guard !isClosing, isPinned, requestedScale.isFinite,
              let window, let native = pinnedNativeSize,
              native.width > 0, native.height > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let maximum = max(0.01, min(4, min(visible.width / native.width, visible.height / native.height)))
        // The host, rather than the image's short edge, protects the close
        // control. A thin capture must still be able to zoom out.
        let minimum = min(maximum, 0.1)
        let scale = min(max(requestedScale, minimum), maximum)
        let previous = window.frame
        // Keep a usable close target even for a tiny or very thin capture.
        // Only the presentation host gets this minimum; the immutable image
        // retains its aspect ratio and original pixels.
        let size = CGSize(
            width: min(visible.width, max(72, native.width * scale)),
            height: min(visible.height, max(72, native.height * scale))
        )
        let pointer = NSEvent.mouseLocation
        let anchor = preservePointer && previous.contains(pointer) ? pointer : CGPoint(x: previous.midX, y: previous.midY)
        let relativeX = (anchor.x - previous.minX) / max(previous.width, 1)
        let relativeY = (anchor.y - previous.minY) / max(previous.height, 1)
        var frame = CGRect(x: anchor.x - size.width * relativeX, y: anchor.y - size.height * relativeY, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        pinnedScale = scale
        canvas.pinnedDisplayScale = scale
        window.setFrame(frame, display: true, animate: false)
        canvas.needsDisplay = true
    }

    @objc private func saveImage() {
        canvas.endKeyboardNudgeGroup()
        guard !isClosing, imageExportTask == nil, savePanel == nil else { return }
        if settings.askSaveLocation || settings.saveDirectoryURL == nil {
            guard let window else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = settings.suggestedFileName()
            panel.canCreateDirectories = true
            imageExportGeneration &+= 1
            let generation = imageExportGeneration
            savePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak panel] response in
                guard let self, !self.isClosing,
                      self.imageExportGeneration == generation,
                      self.savePanel === panel else { return }
                self.savePanel = nil
                guard response == .OK, let destination = panel?.url else { return }
                self.exportImage(to: destination, scopedFolder: nil)
            }
        } else if let folder = settings.saveDirectoryURL {
            let isAccessingScope = folder.startAccessingSecurityScopedResource()
            let destination = uniqueURL(in: folder, named: settings.suggestedFileName())
            exportImage(to: destination, scopedFolder: isAccessingScope ? folder : nil)
        }
    }

    private func exportImage(to destination: URL, scopedFolder: URL?) {
        guard !isClosing, imageExportTask == nil,
              let image = canvas.flattenedCGImage() else {
            scopedFolder?.stopAccessingSecurityScopedResource()
            showFeedback(title: "无法保存截图", message: "请重试。")
            return
        }
        imageExportGeneration &+= 1
        let generation = imageExportGeneration
        showFeedback(title: "正在保存…", message: "", symbol: "arrow.triangle.2.circlepath", duration: nil)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try PNGImageEncoder.encode(image)
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
        }
        imageExportWorkerCancellation = { worker.cancel() }
        imageExportTask = Task { [weak self] in
            defer { scopedFolder?.stopAccessingSecurityScopedResource() }
            do {
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self, !self.isClosing, self.imageExportGeneration == generation else { return }
                self.imageExportWorkerCancellation = nil
                self.imageExportTask = nil
                self.settings.recordSavedURL(destination)
                self.showFeedback(title: "已保存", message: destination.lastPathComponent, symbol: "checkmark.circle.fill", duration: 1.6)
            } catch {
                guard let self, !self.isClosing, self.imageExportGeneration == generation else { return }
                self.imageExportWorkerCancellation = nil
                self.imageExportTask = nil
                guard !(error is CancellationError) else { return }
                self.showFeedback(title: "保存失败", message: error.localizedDescription)
            }
        }
    }

    private func uniqueURL(in folder: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private func showFeedback(
        title: String,
        message: String,
        symbol: String = "exclamationmark.circle",
        duration: TimeInterval? = 4.5
    ) {
        guard !isClosing else { return }
        feedbackPresentationID = CopyConfirmationPresenter.shared.show(
            title: title,
            message: message,
            symbol: symbol,
            on: window?.screen,
            duration: duration
        )
    }

    @objc private func closeEditor() { close() }

    @objc private func startLongScreenshot() {
        guard !isClosing, imageExportTask == nil, savePanel == nil,
              let anchor = captureSourceTopLeft, let start = onLongScreenshot else { return }
        guard let seed = canvas.longScreenshotSeed(sourceTopLeft: anchor) else {
            showFeedback(title: "请先圈范围，再开始长截图", message: "长截图从原画面开始。现有标注不会被丢弃，请重新圈选。")
            return
        }
        do { try start(seed) }
        catch { showFeedback(title: "无法开始长截图", message: error.localizedDescription) }
    }

    @objc private func finishEditing() {
        canvas.endKeyboardNudgeGroup()
        guard !isClosing, canvas.isEditing, imageExportTask == nil, savePanel == nil,
              let image = canvas.flattenedCGImage() else { return }
        let screen = window?.screen ?? NSScreen.main
        imageExportGeneration &+= 1
        let generation = imageExportGeneration
        showFeedback(title: "正在复制…", message: "", symbol: "arrow.triangle.2.circlepath", duration: nil)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try PNGImageEncoder.encode(image)
            try Task.checkCancellation()
            return data
        }
        imageExportWorkerCancellation = { worker.cancel() }
        imageExportTask = Task { [weak self] in
            do {
                let data = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self, !self.isClosing, self.imageExportGeneration == generation else { return }
                self.imageExportWorkerCancellation = nil
                self.imageExportTask = nil
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setData(data, forType: .png) else {
                    self.showFeedback(title: "复制失败", message: "请重试，或将截图保存为 PNG。")
                    return
                }
                self.close()
                CopyConfirmationPresenter.shared.show(on: screen)
            } catch {
                guard let self, !self.isClosing, self.imageExportGeneration == generation else { return }
                self.imageExportWorkerCancellation = nil
                self.imageExportTask = nil
                guard !(error is CancellationError) else { return }
                self.showFeedback(title: "复制失败", message: error.localizedDescription)
            }
        }
    }

    private func installCloseKeyMonitor() {
        guard closeKeyMonitor == nil else { return }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isNudgeKey = (123...126).contains(event.keyCode)
                && !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
            if !isNudgeKey { self.canvas.endKeyboardNudgeGroup() }
            if flags.contains(.command), event.charactersIgnoringModifiers == "." {
                self.close()
                return nil
            }
            let isCommandW = flags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "w"
            if isCommandW {
                self.close()
                return nil
            }
            let isCommandZ = flags.contains(.command)
                && !flags.contains(.control)
                && !flags.contains(.option)
                && event.charactersIgnoringModifiers?.lowercased() == "z"
            if isCommandZ, !self.canvas.isEnteringText, self.canvas.isEditing {
                if flags.contains(.shift) {
                    self.redo()
                } else {
                    self.undo()
                }
                return nil
            }
            if event.keyCode == 53, !self.canvas.isEnteringText {
                self.close()
                return nil
            }
            if !self.canvas.isEnteringText,
               self.canvas.isEditing,
               (event.keyCode == 36 || event.keyCode == 76),
               !flags.contains(.command),
               !flags.contains(.control),
               !flags.contains(.option) {
                self.finishEditing()
                return nil
            }
            if !self.canvas.isEnteringText,
               self.canvas.isEditing,
               !flags.contains(.command),
               !flags.contains(.control),
               !flags.contains(.option),
               let character = event.charactersIgnoringModifiers,
               let number = Int(character),
               EditorTool.toolbarTools.indices.contains(number - 1) {
                let tool = EditorTool.toolbarTools[number - 1]
                self.setTool(tool)
                return nil
            }
            return event
        }
    }

    private func positionToolbar() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        positionTextResult()
        let editorFrame = window.frame
        let visible = screen.visibleFrame
        fitToolbar(availableWidth: max(240, visible.width - CaptureAppearance.toolbarScreenInset * 2))
        var toolbarFrame = toolbarPanel.frame
        let horizontalInset = CaptureAppearance.toolbarScreenInset
        let centeredX = editorFrame.midX - toolbarFrame.width / 2
        let minimumX = visible.minX + horizontalInset
        let maximumX = visible.maxX - toolbarFrame.width - horizontalInset
        toolbarFrame.origin.x = maximumX >= minimumX
            ? min(max(centeredX, minimumX), maximumX)
            : visible.midX - toolbarFrame.width / 2
        let belowY = editorFrame.minY - toolbarFrame.height - 8
        let aboveY = editorFrame.maxY + 8
        let placementStillFits = (toolbarPlacement == .below && belowY >= visible.minY + 8)
            || (toolbarPlacement == .above && aboveY + toolbarFrame.height <= visible.maxY - 8)
        if toolbarPlacement == nil || (!isCanvasInteracting && !placementStillFits) {
            if belowY >= visible.minY + 8 {
                toolbarPlacement = .below
            } else if aboveY + toolbarFrame.height <= visible.maxY - 8 {
                toolbarPlacement = .above
            } else {
                toolbarPlacement = .inside
            }
        }
        let candidateY: CGFloat
        switch toolbarPlacement ?? .inside {
        case .below: candidateY = belowY
        case .above: candidateY = aboveY
        case .inside: candidateY = visible.minY + 8
        }
        toolbarFrame.origin.y = min(max(candidateY, visible.minY + 8), visible.maxY - toolbarFrame.height - 8)
        if toolbarPanel.frame != toolbarFrame { toolbarPanel.setFrame(toolbarFrame, display: true) }
    }

    private func fitToolbar(availableWidth: CGFloat) {
        guard let toolbar = toolbarStack, let host = toolbarHost else { return }
        let compact = toolbarNaturalSize.width > availableWidth
        let needsRefit = compact != toolbarIsCompact || (compact && toolbarAvailableWidth != availableWidth)
        toolbarAvailableWidth = availableWidth
        guard needsRefit else { return }
        toolbarIsCompact = compact
        for group in toolbarGroups {
            (group.superview as? NSStackView)?.removeArrangedSubview(group)
            group.removeFromSuperview()
        }
        for view in toolbar.arrangedSubviews {
            toolbar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        toolbar.orientation = compact ? .vertical : .horizontal
        toolbar.alignment = compact ? .centerX : .centerY
        if compact {
            var rows: [NSStackView] = []
            for pair in [[toolbarGroups[0], toolbarGroups[1]], [toolbarGroups[2], toolbarGroups[3]]] {
                let row = toolbarGroup(spacing: 8)
                row.addArrangedSubview(pair[0])
                row.addArrangedSubview(toolbarSeparator())
                row.addArrangedSubview(pair[1])
                toolbar.addArrangedSubview(row)
                rows.append(row)
            }
            if let top = rows.first,
               top.fittingSize.width + CaptureAppearance.toolbarHorizontalPadding * 2 > availableWidth {
                top.removeArrangedSubview(toolbarGroups[1])
                toolbarGroups[1].removeFromSuperview()
                toolbar.insertArrangedSubview(toolbarGroups[1], at: 1)
            }
        } else {
            for (index, group) in toolbarGroups.enumerated() {
                if index > 0 { toolbar.addArrangedSubview(toolbarSeparator()) }
                toolbar.addArrangedSubview(group)
            }
        }
        toolbar.layoutSubtreeIfNeeded()
        let fitting = toolbar.fittingSize
        let size = CGSize(width: ceil(fitting.width) + CaptureAppearance.toolbarHorizontalPadding * 2, height: max(CaptureAppearance.toolbarHeight, ceil(fitting.height) + 16))
        toolbarPanel.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        toolbar.frame = NSRect(
            x: (size.width - fitting.width) / 2,
            y: (size.height - fitting.height) / 2,
            width: fitting.width,
            height: fitting.height
        )
    }

    private func resizeCanvas(to size: CGSize) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        positionToolbar()
        onFrameChange?(frame)
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        colorWell.dismissPalette()
        canvas.cancelTemporaryInteraction()
        cancelBackgroundWork()
        if let closeKeyMonitor {
            NSEvent.removeMonitor(closeKeyMonitor)
            self.closeKeyMonitor = nil
        }
        toolbarPanel.orderOut(nil)
        window?.removeChildWindow(toolbarPanel)
        textResultController?.close()
        textResultController = nil
        onFrameChange = nil
        onBackdropDismissRequest = nil
        onPresentationActiveChange = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingViewportFrame else { return }
        guard let frame = window?.frame else { return }
        if canvas.isEditing { positionToolbar() }
        else { positionTextResult() }
        onFrameChange?(frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingViewportFrame else { return }
        if canvas.isEditing { positionToolbar() }
        else { positionTextResult() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isClosing, canvas.isEditing else { return }
        if usesFrozenBackdrop {
            window?.level = .statusBar
            toolbarPanel.level = .statusBar
        }
        onPresentationActiveChange?(true)
        positionToolbar()
        toolbarPanel.orderFront(nil)
        textResultController?.revealWithoutTakingFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        canvas.endTemporaryMove()
        deferPresentationSuspension()
    }

    private func deferPresentationSuspension() {
        // Key-window transitions finish after this delegate callback. Wait one
        // event turn so an owned save sheet or color panel is not mistaken for
        // the user switching to settings or another application.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosing, self.canvas.isEditing,
                  self.window?.isVisible == true,
                  self.window?.isKeyWindow != true,
                  self.window?.attachedSheet == nil else { return }
            if NSApp.isActive, NSApp.keyWindow === self.toolbarPanel { return }
            // Transient popovers can briefly have no key window. That gap is
            // not an application switch and must not tear down the color UI.
            if NSApp.isActive, self.colorWell.isPaletteOpen, NSApp.keyWindow == nil { return }
            if NSApp.isActive, let paletteWindow = self.colorWell.paletteWindow,
               NSApp.keyWindow === paletteWindow { return }
            if NSApp.isActive, NSApp.keyWindow === self.textResultController?.window { return }
            self.colorWell.dismissPalette()
            self.canvas.cancelTemporaryInteraction()
            self.toolbarPanel.orderOut(nil)
            self.toolbarPanel.level = .normal
            self.window?.level = .normal
            self.onPresentationActiveChange?(false)
        }
    }
}

final class EditorOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class PinnedImageCloseButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
        layer?.shadowRadius = 3
        layer?.shadowOpacity = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        updateHoverAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateHoverAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateHoverAppearance() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverAppearance()
    }

    private func updateHoverAppearance() {
        let opaque = isHovered || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(opaque ? 1 : 0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
    }
}

@MainActor
private final class CopyConfirmationPresenter {
    static let shared = CopyConfirmationPresenter()

    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?
    private var presentationID = 0

    private init() {
        let size = CGSize(width: 220, height: 46)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
    }

    func show(on screen: NSScreen?) {
        show(title: "已复制到剪贴板", message: "", symbol: "checkmark.circle.fill", on: screen, duration: 1.6)
    }

    @discardableResult
    func show(title: String, message: String, symbol: String, on screen: NSScreen?, duration: TimeInterval?) -> Int {
        hideWorkItem?.cancel()
        presentationID += 1
        let currentPresentationID = presentationID
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let toast = CaptureToastView(title: title, message: message, symbol: symbol)
        toast.layoutSubtreeIfNeeded()
        let fitting = toast.fittingSize
        let size = CGSize(
            width: min(max(184, ceil(max(fitting.width, toast.frame.width))), max(184, visibleFrame.width - 32)),
            height: max(46, ceil(max(fitting.height, toast.frame.height)))
        )
        toast.frame = NSRect(origin: .zero, size: size)
        toast.autoresizingMask = [.width, .height]
        panel.setContentSize(size)
        panel.contentView = toast
        let panelSize = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + 72
        ))
        let animate = !panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.orderFrontRegardless()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        if let duration {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.presentationID == currentPresentationID else { return }
                self.panel.orderOut(nil)
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
        }
        return currentPresentationID
    }

    func dismiss(_ id: Int?) {
        guard let id, id == presentationID else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        presentationID += 1
        panel.orderOut(nil)
    }
}

final class EditorCanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    private enum AnnotationHistoryEntry {
        case added(index: Int, annotation: Annotation)
        case replaced(index: Int, before: Annotation, after: Annotation)
        case removed(index: Int, annotation: Annotation)
        case viewport(before: CGRect, after: CGRect)
    }

    private enum RectangleResizeHandle: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    private enum ViewportResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    var onSizeChange: ((CGSize) -> Void)?
    /// Source-image points, with a top-left origin. Moving/resizing a live
    /// selection changes its viewport within the same immutable capture.
    var onViewportChange: ((CGRect, CGRect) -> Void)?
    var onToolChangeRequest: ((EditorTool) -> Void)?
    var onTextSizeChangeRequest: ((EditorTextSize) -> Void)?
    var onSelectionToolChange: ((EditorTool?) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?
    var onHistoryChange: (() -> Void)?
    var onPinnedZoom: ((CGFloat) -> Void)?
    var onPinnedReset: (() -> Void)?
    var pinnedDisplayScale: CGFloat = 1
    var isEditing = true {
        didSet {
            if !isEditing {
                updateHoveredAnnotation(nil)
                commitInlineText()
                finishGeometryGesture()
                setSpacePressed(false)
            }
            onHistoryChange?()
            needsDisplay = true
        }
    }
    var tool: EditorTool = .move {
        didSet {
            guard tool != oldValue else { return }
            // Changing a tool does not change screenshot pixels. Only erase
            // the old draft/hover, rather than repainting the entire bitmap.
            let previousDraftRects = draftInvalidationRects(for: oldValue)
            if inlineTextView != nil { commitInlineText() }
            updateHoveredAnnotation(nil)
            finishGeometryGesture()
            previousDraftRects.forEach(invalidateDisplay)
            window?.invalidateCursorRects(for: self)
        }
    }
    var strokeColor: NSColor = .systemRed {
        didSet {
            applyInlineColor(strokeColor)
        }
    }
    var strokeWidth: CGFloat = 4
    private(set) var textFontSize = EditorTextSize.medium.pointSize

    private var baseImage: CGImage
    private var imagePointSize: CGSize
    private var displayImage: NSImage
    private var sourceImage: CGImage
    private var sourcePointSize: CGSize
    private var viewport: CGRect
    private var annotations: [Annotation] = []
    private struct TextMeasurementKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let layoutWidth: CGFloat
    }
    // Session-only glyph metrics, not image/history storage. Moving text or
    // drawing another shape must not relayout every unchanged text label.
    private var textMeasurements: [TextMeasurementKey: CGSize] = [:]
    private var undoStack: [AnnotationHistoryEntry] = []
    private var redoStack: [AnnotationHistoryEntry] = []
    private struct KeyboardNudgeGroup {
        let index: Int
        let before: Annotation
        var after: Annotation
        var lastTimestamp: TimeInterval
        var lastKeyCode: UInt16
    }
    private var keyboardNudgeGroup: KeyboardNudgeGroup?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var penPoints: [CGPoint] = []
    private var inlineTextView: InlineAnnotationTextView?
    private var inlineTextContainer: NSView?
    private var inlineTextHost: NSView?
    private var inlineTextScrollView: NSScrollView?
    private var inlineTextPoint: CGPoint?
    private var inlineTextAnchor: CGPoint?
    private var inlineTextLayoutWidth: CGFloat?
    private var inlineTextLayoutMode: TextLayoutMode?
    private var inlineTextFontSize: CGFloat?
    private var inlineEditingTextIndex: Int?
    private var isFinishingInlineText = false
    private var isResizingInlineText = false
    private var selectedAnnotationIndex: Int? {
        didSet {
            if selectedAnnotationIndex != oldValue {
                endKeyboardNudgeGroup()
                window?.invalidateCursorRects(for: self)
            }
            notifySelectionContextChange()
        }
    }
    private var movingTextStart: CGPoint?
    private var movingTextOriginalPoint: CGPoint?
    private var resizingTextIndex: Int?
    private var resizingTextOriginalSize: CGFloat?
    private var resizingTextOriginalLayoutWidth: CGFloat?
    private var resizingTextOriginalLayoutMode: TextLayoutMode?
    private var resizingTextStartPoint: CGPoint?
    private var transformingAnnotationIndex: Int?
    private var transformingAnnotationOriginal: Annotation?
    private var didTransformAnnotation = false
    private var movingAnnotationIndex: Int?
    private var movingAnnotationStart: CGPoint?
    private var movingAnnotationOriginal: Annotation?
    private var resizingShapeIndex: Int?
    private var resizingShapeOriginal: Annotation?
    private var resizingShapeHandle: RectangleResizeHandle?
    private var resizingLineIndex: Int?
    private var resizingLineStartEndpoint = false
    private var viewportResizeHandle: ViewportResizeHandle?
    private var viewportResizeOriginal: CGRect?
    private var viewportResizeScreenStart: CGPoint?
    private var viewportMoveOriginal: CGRect?
    private var viewportMoveScreenStart: CGPoint?
    private var canvasTrackingArea: NSTrackingArea?
    private var hoveredViewportHandle: ViewportResizeHandle?
    private var hoveredAnnotationIndex: Int?
    private var isInteracting = false
    private var isDraggingCanvasWindow = false
    private var isSpacePressed = false

    var isEnteringText: Bool { inlineTextView != nil }
    var canUndo: Bool {
        guard isEditing else { return false }
        if let inlineTextView { return inlineTextView.undoManager?.canUndo == true }
        return !undoStack.isEmpty
    }
    var canRedo: Bool {
        guard isEditing else { return false }
        if let inlineTextView { return inlineTextView.undoManager?.canRedo == true }
        return !redoStack.isEmpty
    }
    var undoTitle: String {
        guard canUndo else { return "撤销" }
        if isEnteringText { return "撤销文字输入" }
        return "撤销" + (undoStack.last.map(historyActionTitle) ?? "")
    }
    var redoTitle: String {
        guard canRedo else { return "重做" }
        if isEnteringText { return "重做文字输入" }
        return "重做" + (redoStack.last.map(historyActionTitle) ?? "")
    }
    var selectedAnnotationTool: EditorTool? {
        if isEnteringText { return .text }
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return nil }
        switch annotations[index] {
        case let .line(_, _, _, _, arrow): return arrow ? .arrow : .line
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .text: return .text
        case .mosaic: return .mosaic
        }
    }
    var selectedAnnotationColor: NSColor? {
        if let inlineTextView { return inlineTextView.textColor }
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return nil }
        switch annotations[index] {
        case let .line(_, _, color, _, _), let .rectangle(_, color, _),
             let .ellipse(_, color, _), let .pen(_, color, _), let .text(_, _, color, _, _, _): return color
        case .mosaic: return nil
        }
    }
    var selectedAnnotationStrokeWidth: CGFloat? {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return nil }
        switch annotations[index] {
        case let .line(_, _, _, width, _), let .rectangle(_, _, width),
             let .ellipse(_, _, width), let .pen(_, _, width): return width
        case .text, .mosaic: return nil
        }
    }
    var selectedAnnotationFontSize: CGFloat? {
        if let inlineTextFontSize { return inlineTextFontSize }
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index),
              case let .text(_, _, _, fontSize, _, _) = annotations[index] else { return nil }
        return fontSize
    }

    func applySelectedStyle(color: NSColor? = nil, strokeWidth: CGFloat? = nil) {
        endKeyboardNudgeGroup()
        if inlineTextView != nil {
            if let color { applyInlineColor(color) }
            return
        }
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        let before = annotations[index]
        func updated(_ previousColor: NSColor, _ previousWidth: CGFloat) -> (NSColor, CGFloat, Bool) {
            let nextColor = color ?? previousColor
            let nextWidth = strokeWidth.map { min(20, max(1, $0)) } ?? previousWidth
            return (nextColor, nextWidth, !nextColor.isEqual(previousColor) || abs(nextWidth - previousWidth) > 0.01)
        }
        let after: Annotation
        switch before {
        case let .line(start, end, previousColor, width, arrow):
            let (nextColor, nextWidth, changed) = updated(previousColor, width)
            guard changed else { return }
            after = .line(start, end, nextColor, nextWidth, arrow)
        case let .rectangle(rect, previousColor, width):
            let (nextColor, nextWidth, changed) = updated(previousColor, width)
            guard changed else { return }
            after = .rectangle(rect, nextColor, nextWidth)
        case let .ellipse(rect, previousColor, width):
            let (nextColor, nextWidth, changed) = updated(previousColor, width)
            guard changed else { return }
            after = .ellipse(rect, nextColor, nextWidth)
        case let .pen(points, previousColor, width):
            let (nextColor, nextWidth, changed) = updated(previousColor, width)
            guard changed else { return }
            after = .pen(points, nextColor, nextWidth)
        case let .text(text, point, previousColor, fontSize, layoutWidth, layoutMode):
            guard let color, !color.isEqual(previousColor) else { return }
            after = .text(text, point, color, fontSize, layoutWidth, layoutMode)
        case .mosaic: return
        }
        finishGeometryGesture()
        let oldBounds = selectionDisplayBounds(at: index)
        annotations[index] = after
        recordHistory(.replaced(index: index, before: before, after: after))
        invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
        notifySelectionContextChange()
    }

    private func applyInlineColor(_ requestedColor: NSColor) {
        guard let textView = inlineTextView,
              let color = requestedColor.usingColorSpace(.sRGB) else { return }
        let previous = textView.textColor ?? strokeColor
        guard previous.usingColorSpace(.sRGB)?.isEqual(color) != true else { return }
        textView.breakUndoCoalescing()
        textView.undoManager?.registerUndo(withTarget: textView) { [weak self] originalView in
            MainActor.assumeIsolated {
                guard let self, self.inlineTextView === originalView else { return }
                self.applyInlineColor(previous)
            }
        }
        textView.undoManager?.setActionName("文字颜色")
        textView.textColor = color
        textView.insertionPointColor = color
        var attributes = textView.typingAttributes
        attributes[.foregroundColor] = color
        textView.typingAttributes = attributes
        notifySelectionContextChange()
    }
    var hasSelectedText: Bool {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex),
              case .text = annotations[selectedAnnotationIndex] else { return false }
        return true
    }

    init(image: CapturedImage) {
        baseImage = image.cgImage
        imagePointSize = image.pointSize
        displayImage = NSImage(cgImage: image.cgImage, size: image.pointSize)
        sourceImage = image.sourceCGImage ?? image.cgImage
        sourcePointSize = image.sourcePointSize ?? image.pointSize
        viewport = image.selectionRect ?? CGRect(origin: .zero, size: image.pointSize)
        super.init(frame: NSRect(origin: .zero, size: image.pointSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { endKeyboardNudgeGroup() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let canvasTrackingArea { removeTrackingArea(canvasTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        canvasTrackingArea = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEditing else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredViewportHandle(viewportResizeHandle(at: point))
        updateHoveredAnnotation(actionableAnnotationIndex(at: point))
        cursor(at: point).set()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        updateHoveredViewportHandle(nil)
        updateHoveredAnnotation(nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    private func actionableAnnotationIndex(at point: CGPoint) -> Int? {
        guard isEditing, !isEnteringText, !isSpacePressed, !isInteracting,
              bounds.contains(point), viewportResizeHandle(at: point) == nil,
              let index = annotationIndex(at: point),
              tool == .move || toolMatchesAnnotation(annotations[index]) else { return nil }
        return index
    }

    private func updateHoveredAnnotation(_ index: Int?) {
        guard index != hoveredAnnotationIndex else { return }
        let previousRects = hoverInvalidationRects(at: hoveredAnnotationIndex)
        hoveredAnnotationIndex = index
        previousRects.forEach(invalidateDisplay)
        hoverInvalidationRects(at: index).forEach(invalidateDisplay)
    }

    private func hoverInvalidationRects(at index: Int?) -> [CGRect] {
        guard let index, annotations.indices.contains(index) else { return [] }
        if case let .line(start, end, _, _, _) = annotations[index] {
            return [start, end].map { CGRect(x: $0.x - 5, y: $0.y - 5, width: 10, height: 10) }
        }
        return borderInvalidationRects(for: annotationCoreBounds(annotations[index]).insetBy(dx: -4, dy: -4), padding: 3)
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        if isInteracting, isDraggingCanvasWindow || viewportMoveOriginal != nil || movingAnnotationIndex != nil || movingTextStart != nil { return .closedHand }
        if !isEditing || isSpacePressed { return .openHand }
        if inlineTextContainer?.frame.contains(point) == true { return .iBeam }
        if let index = selectedAnnotationIndex {
            if textResizeHandleRect(at: index)?.insetBy(dx: -4, dy: -4).contains(point) == true
                || rectangleResizeHandle(at: point, index: index) != nil
                || lineResizeHandles(at: index).contains(where: { $0.1.insetBy(dx: -4, dy: -4).contains(point) }) {
                return .crosshair
            }
        }
        if viewportResizeHandle(at: point) != nil { return .crosshair }
        if actionableAnnotationIndex(at: point) != nil { return .pointingHand }
        return tool == .move ? .openHand : .crosshair
    }

    private func updateHoveredViewportHandle(_ handle: ViewportResizeHandle?) {
        guard handle != hoveredViewportHandle else { return }
        let previous = hoveredViewportHandle
        hoveredViewportHandle = handle
        for (candidate, rect) in viewportResizeHandles() where candidate == previous || candidate == handle {
            invalidateDisplay(rect.insetBy(dx: -3, dy: -3))
        }
    }

    private func setInteractionActive(_ active: Bool) {
        guard active != isInteracting else { return }
        isInteracting = active
        if active { updateHoveredAnnotation(nil) }
        window?.invalidateCursorRects(for: self)
        onInteractionChange?(active)
    }

    private func performWindowDrag(with event: NSEvent) {
        guard let window else { return }
        // Native window dragging runs a nested event loop. Notify before the
        // handoff so the toolbar's first movement already uses a stable side.
        isDraggingCanvasWindow = true
        setInteractionActive(true)
        NSCursor.closedHand.set()
        defer {
            isDraggingCanvasWindow = false
            setInteractionActive(false)
            // Native tracking can consume keyUp. Release the temporary cursor
            // at the end of this gesture as a local fail-safe.
            setSpacePressed(false)
        }
        window.performDrag(with: event)
    }

    private func beginViewportMove(with event: NSEvent) {
        guard isEditing, let pointer = viewportPointer(for: event) else { return }
        finishGeometryGesture()
        viewportMoveOriginal = viewport
        viewportMoveScreenStart = pointer
        setInteractionActive(true)
        NSCursor.closedHand.set()
    }

    private func viewportPointer(for event: NSEvent) -> CGPoint? {
        // Read the position stored in this app's mouse event, not a later
        // global cursor sample or coordinates relative to a moving window.
        event.cgEvent?.unflippedLocation ?? window?.convertPoint(toScreen: event.locationInWindow)
    }

    private func updateViewportMove(with event: NSEvent) {
        guard let original = viewportMoveOriginal,
              let screenStart = viewportMoveScreenStart,
              let pointer = viewportPointer(for: event) else { return }
        let scaleX = CGFloat(sourceImage.width) / sourcePointSize.width
        let scaleY = CGFloat(sourceImage.height) / sourcePointSize.height
        // Snap the origin, not the two sides independently. A pan keeps the
        // crop's exact pixel size even at a fractional Retina point position.
        let pixelWidth = min(CGFloat(sourceImage.width), (original.width * scaleX).rounded())
        let pixelHeight = min(CGFloat(sourceImage.height), (original.height * scaleY).rounded())
        let pixelX = min(max(0, ((original.minX + pointer.x - screenStart.x) * scaleX).rounded()),
                         CGFloat(sourceImage.width) - pixelWidth)
        let pixelY = min(max(0, ((original.minY + screenStart.y - pointer.y) * scaleY).rounded()),
                         CGFloat(sourceImage.height) - pixelHeight)
        setViewport(CGRect(x: pixelX / scaleX, y: pixelY / scaleY,
                           width: pixelWidth / scaleX, height: pixelHeight / scaleY))
    }

    private func setSpacePressed(_ pressed: Bool) {
        guard isSpacePressed != pressed else { return }
        isSpacePressed = pressed
        if pressed { updateHoveredAnnotation(nil) }
        window?.invalidateCursorRects(for: self)
    }

    func cancelTemporaryInteraction() {
        setSpacePressed(false)
        finishGeometryGesture()
    }

    func endTemporaryMove() {
        endKeyboardNudgeGroup()
        setSpacePressed(false)
    }

    func endKeyboardNudgeGroup() { keyboardNudgeGroup = nil }

    private func notifySelectionContextChange() {
        if let index = selectedAnnotationIndex,
           annotations.indices.contains(index),
           case let .text(_, _, _, fontSize, _, _) = annotations[index] {
            textFontSize = fontSize
        } else if let inlineTextFontSize {
            textFontSize = inlineTextFontSize
        }
        onSelectionToolChange?(selectedAnnotationTool)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var imageRect = bounds
        if !isEditing, imagePointSize.width > 0, imagePointSize.height > 0 {
            let scale = min(pinnedDisplayScale, min(bounds.width / imagePointSize.width, bounds.height / imagePointSize.height))
            let size = CGSize(width: imagePointSize.width * scale, height: imagePointSize.height * scale)
            imageRect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            NSColor.black.setFill()
            bounds.fill()
        }
        displayImage.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        for (index, annotation) in annotations.enumerated()
        where index != inlineEditingTextIndex && annotationDisplayBounds(annotation).intersects(dirtyRect) {
            drawAnnotation(annotation)
        }
        if isEditing {
            drawAnnotationHover()
            drawAnnotationSelection()
            drawDraft()
            drawCaptureBoundary()
            drawViewportHandles()
        }
    }

    private func drawCaptureBoundary() {
        guard bounds.width > 3, bounds.height > 3 else { return }
        let outerRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outerRadius = min(CaptureAppearance.selectionCornerRadius, min(outerRect.width, outerRect.height) / 2)
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: outerRadius, yRadius: outerRadius)
        CaptureAppearance.selectionDarkOutline.setStroke()
        outer.lineWidth = 1
        outer.stroke()
        let innerRect = bounds.insetBy(dx: 1.25, dy: 1.25)
        let innerRadius = min(CaptureAppearance.selectionCornerRadius, min(innerRect.width, innerRect.height) / 2)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)
        CaptureAppearance.selectionLightOutline.withAlphaComponent(0.78).setStroke()
        inner.lineWidth = 0.75
        inner.stroke()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let movingObject = isInteracting && (isDraggingCanvasWindow || viewportMoveOriginal != nil || movingAnnotationIndex != nil || movingTextStart != nil)
        addCursorRect(bounds, cursor: movingObject ? .closedHand : (!isEditing || isSpacePressed || tool == .move ? .openHand : .crosshair))
        guard isEditing else { return }
        guard !isSpacePressed else { return }
        for rect in viewportEdgeCursorRects() {
            addCursorRect(rect, cursor: .crosshair)
        }
        for (_, rect) in viewportResizeHandles() {
            addCursorRect(rect.insetBy(dx: -2, dy: -2), cursor: .crosshair)
        }
        guard let selectedAnnotationIndex else { return }
        if let handle = textResizeHandleRect(at: selectedAnnotationIndex) {
            addCursorRect(handle.insetBy(dx: -3, dy: -3), cursor: .crosshair)
        }
        for (_, handle) in rectangleResizeHandles(at: selectedAnnotationIndex) {
            addCursorRect(handle.insetBy(dx: -3, dy: -3), cursor: .crosshair)
        }
        for (_, handle) in lineResizeHandles(at: selectedAnnotationIndex) {
            addCursorRect(handle.insetBy(dx: -3, dy: -3), cursor: .crosshair)
        }
    }

    func applyInitialGesture(_ gesture: EditorInitialGesture, for tool: EditorTool) {
        guard isEditing else { return }
        commitInlineText()
        selectedAnnotationIndex = nil

        switch (tool, gesture) {
        case let (.text, .tap(point)):
            beginInlineText(at: bounded(point))
        case let (.line, .drag(start, end)):
            add(.line(bounded(start), bounded(end), strokeColor, strokeWidth, false))
        case let (.arrow, .drag(start, end)):
            let start = bounded(start)
            let end = bounded(end)
            if hypot(end.x - start.x, end.y - start.y) > 1 {
                add(.line(start, end, strokeColor, strokeWidth, true))
            }
        case let (.rectangle, .drag(start, end)):
            let rect = normalizedRect(bounded(start), bounded(end))
            if rect.width > 2, rect.height > 2 {
                add(.rectangle(rect, strokeColor, strokeWidth))
            }
        case let (.ellipse, .drag(start, end)):
            let rect = normalizedRect(bounded(start), bounded(end))
            if rect.width > 2, rect.height > 2 {
                add(.ellipse(rect, strokeColor, strokeWidth))
            }
        case let (.pen, .freehand(points)):
            let boundedPoints = points.map(bounded)
            if boundedPoints.count > 1 {
                add(.pen(boundedPoints, strokeColor, strokeWidth))
            }
        case let (.mosaic, .drag(start, end)):
            let rect = normalizedRect(bounded(start), bounded(end))
            if rect.width > 2, rect.height > 2 { add(.mosaic(rect)) }
        case let (.crop, .drag(start, end)):
            let rect = normalizedRect(bounded(start), bounded(end))
            if rect.width > 4, rect.height > 4 { applyCrop(rect) }
        default:
            break
        }
        needsDisplay = true
    }

    func focusInlineText() {
        guard let inlineTextView else { return }
        window?.makeFirstResponder(inlineTextView)
    }

    func applyTextSize(_ size: EditorTextSize, updateSelection: Bool) {
        endKeyboardNudgeGroup()
        textFontSize = size.pointSize
        if let textView = inlineTextView {
            inlineTextFontSize = size.pointSize
            configureInlineTypography(textView, color: textView.textColor ?? strokeColor, fontSize: size.pointSize)
            resizeInlineTextEditor()
            notifySelectionContextChange()
            return
        }
        guard updateSelection,
              let index = selectedAnnotationIndex,
              annotations.indices.contains(index),
              case let .text(text, point, color, oldSize, layoutWidth, layoutMode) = annotations[index],
              abs(oldSize - size.pointSize) > 0.01 else { return }
        let before = annotations[index]
        let oldBounds = selectionDisplayBounds(at: index)
        let newWidth = layoutMode == .auto
            ? automaticTextLayoutWidth(text, color: color, fontSize: size.pointSize, anchor: point)
            : layoutWidth
        let after = Annotation.text(text, point, color, size.pointSize, newWidth, layoutMode)
        annotations[index] = after
        recordHistory(.replaced(index: index, before: before, after: after))
        invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
        notifySelectionContextChange()
    }

    private struct TextLayoutMenuTarget {
        let index: Int
        let snapshot: Annotation
    }

    private var permitsTextLayoutContextMenu: Bool {
        isEditing && window?.isVisible == true && inlineTextView == nil && !isFinishingInlineText
            && !isInteracting && !isDraggingCanvasWindow && !isSpacePressed
            && dragStart == nil && transformingAnnotationIndex == nil && viewportResizeHandle == nil
            && viewportMoveOriginal == nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // NSTextView owns its native editing/IME menu. Never finish or unmark
        // a live input session just because the user right-clicked elsewhere.
        let point = convert(event.locationInWindow, from: nil)
        guard permitsTextLayoutContextMenu, bounds.contains(point),
              let index = annotationIndex(at: point),
              case .text = annotations[index] else { return super.menu(for: event) }
        finishGeometryGesture()
        guard annotations.indices.contains(index),
              case let .text(_, _, _, _, _, mode) = annotations[index] else { return super.menu(for: event) }
        selectTextContextTarget(at: index)
        window?.makeFirstResponder(self)

        let menu = NSMenu()
        // Explicit state prevents responder-chain validation from enabling
        // the action for an already automatic text object.
        menu.autoenablesItems = false
        let restore = NSMenuItem(title: "恢复自适应宽度", action: #selector(restoreAutomaticTextWidth(_:)), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = mode == .fixed
        restore.representedObject = TextLayoutMenuTarget(index: index, snapshot: annotations[index])
        menu.addItem(restore)
        return menu
    }

    private func selectTextContextTarget(at index: Int) {
        let previousSelection = selectedAnnotationIndex.flatMap { selectionDisplayBounds(at: $0) }
        updateHoveredAnnotation(nil)
        selectedAnnotationIndex = index
        invalidateTransition(from: previousSelection, to: selectionDisplayBounds(at: index))
    }

    private func textLayoutMenuTargetIsCurrent(_ target: TextLayoutMenuTarget) -> Bool {
        guard annotations.indices.contains(target.index),
              case .text = target.snapshot else { return false }
        return annotations[target.index] == target.snapshot
    }

    @objc private func restoreAutomaticTextWidth(_ sender: NSMenuItem) {
        guard permitsTextLayoutContextMenu,
              let target = sender.representedObject as? TextLayoutMenuTarget,
              textLayoutMenuTargetIsCurrent(target) else { return }
        finishGeometryGesture()
        guard textLayoutMenuTargetIsCurrent(target),
              case let .text(text, point, color, fontSize, _, mode) = annotations[target.index],
              mode == .fixed else { return }

        selectTextContextTarget(at: target.index)
        let before = annotations[target.index]
        let oldBounds = selectionDisplayBounds(at: target.index)
        let width = automaticTextLayoutWidth(text, color: color, fontSize: fontSize, anchor: point)
        let after = Annotation.text(text, point, color, fontSize, width, .auto)
        annotations[target.index] = after
        recordHistory(.replaced(index: target.index, before: before, after: after))
        invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: target.index))
        window?.invalidateCursorRects(for: self)
        notifySelectionContextChange()
    }

    override func mouseDown(with event: NSEvent) {
        endKeyboardNudgeGroup()
        if inlineTextView != nil { commitInlineText(activateMoveTool: true) }
        guard isEditing else {
            if event.clickCount >= 2 {
                onPinnedReset?()
                return
            }
            performWindowDrag(with: event)
            return
        }
        if isSpacePressed {
            beginViewportMove(with: event)
            return
        }
        let point = bounded(convert(event.locationInWindow, from: nil))
        if let index = selectedAnnotationIndex,
           annotations.indices.contains(index),
           textResizeHandleRect(at: index)?.insetBy(dx: -4, dy: -4).contains(point) == true,
           case let .text(_, _, _, fontSize, layoutWidth, layoutMode) = annotations[index] {
            beginAnnotationTransform(at: index)
            resizingTextIndex = index
            resizingTextOriginalSize = fontSize
            resizingTextOriginalLayoutWidth = layoutWidth
            resizingTextOriginalLayoutMode = layoutMode
            resizingTextStartPoint = point
            movingTextStart = nil
            movingTextOriginalPoint = nil
            return
        }
        if let index = selectedAnnotationIndex,
           let endpoint = lineResizeHandles(at: index).first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(point) }) {
            beginAnnotationTransform(at: index)
            resizingLineIndex = index
            resizingLineStartEndpoint = endpoint.0
            return
        }
        if let index = selectedAnnotationIndex,
           annotations.indices.contains(index),
           let handle = rectangleResizeHandle(at: point, index: index) {
            beginAnnotationTransform(at: index)
            resizingShapeIndex = index
            resizingShapeHandle = handle
            resizingShapeOriginal = annotations[index]
            return
        }
        // Selection handles belong to the capture, not to a drawing tool.
        // Use screen coordinates throughout this gesture because its window
        // frame changes as the user moves an edge.
        if let handle = viewportResizeHandle(at: point), let pointer = viewportPointer(for: event) {
            viewportResizeHandle = handle
            viewportResizeOriginal = viewport
            viewportResizeScreenStart = pointer
            return
        }
        let previousSelection = selectedAnnotationIndex.flatMap { selectionDisplayBounds(at: $0) }
        if let index = annotationIndex(at: point),
           tool == .move || toolMatchesAnnotation(annotations[index]) {
            selectedAnnotationIndex = index
            if case let .text(_, originalPoint, _, fontSize, _, _) = annotations[index] {
                if event.clickCount >= 2 {
                    beginInlineText(editingTextAt: index)
                    return
                }
                beginAnnotationTransform(at: index)
                movingTextStart = point
                movingTextOriginalPoint = originalPoint
                onTextSizeChangeRequest?(.nearest(to: fontSize))
            } else {
                beginAnnotationTransform(at: index)
                movingAnnotationIndex = index
                movingAnnotationStart = point
                movingAnnotationOriginal = annotations[index]
            }
            invalidateTransition(from: previousSelection, to: selectionDisplayBounds(at: index))
            return
        }
        selectedAnnotationIndex = nil
        invalidateDisplay(previousSelection)
        if tool == .move {
            beginViewportMove(with: event)
            return
        }
        dragStart = point
        dragCurrent = point
        penPoints = [point]
        invalidateDraft()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isNudgeKey = (123...126).contains(event.keyCode)
            && !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
        if !isNudgeKey { endKeyboardNudgeGroup() }
        if !isEnteringText,
           !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
           event.keyCode == 49 {
            if isEditing, !isInteracting { setSpacePressed(true) }
            return
        }
        if isEditing, !isEnteringText,
           !flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
           [123, 124, 125, 126].contains(Int(event.keyCode)) {
            nudgeSelectedAnnotation(
                keyCode: event.keyCode, step: flags.contains(.shift) ? 10 : 1,
                timestamp: event.timestamp, isRepeat: event.isARepeat
            )
            return
        }
        if event.keyCode == 53 {
            window?.windowController?.close()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedAnnotation()
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            setSpacePressed(false)
            return
        }
        super.keyUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isEditing else { super.scrollWheel(with: event); return }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.04
        let factor = min(1.2, max(0.83, exp(delta * sensitivity)))
        onPinnedZoom?(factor)
    }

    override func magnify(with event: NSEvent) {
        guard !isEditing else { super.magnify(with: event); return }
        onPinnedZoom?(min(1.4, max(0.7, 1 + event.magnification)))
    }

    private func nudgeSelectedAnnotation(keyCode: UInt16, step: CGFloat, timestamp: TimeInterval, isRepeat: Bool) {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        finishGeometryGesture(preservingKeyboardNudge: true)
        let before = annotations[index]
        let rect = annotationGeometryBounds(before)
        let desiredX: CGFloat = keyCode == 123 ? -step : (keyCode == 124 ? step : 0)
        let desiredY: CGFloat = keyCode == 126 ? -step : (keyCode == 125 ? step : 0)
        let delta = CGPoint(
            x: min(max(desiredX, min(0, -rect.minX)), max(0, bounds.width - rect.maxX)),
            y: min(max(desiredY, min(0, -rect.minY)), max(0, bounds.height - rect.maxY))
        )
        guard abs(delta.x) + abs(delta.y) > 0.001 else { return }
        let oldBounds = selectionDisplayBounds(at: index)
        let after = translatedAnnotation(before, by: delta)
        annotations[index] = after
        recordNudgeHistory(index: index, before: before, after: after,
                           timestamp: timestamp, keyCode: keyCode, isRepeat: isRepeat)
        invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
        window?.invalidateCursorRects(for: self)
    }

    private func recordNudgeHistory(index: Int, before: Annotation, after: Annotation,
                                    timestamp: TimeInterval, keyCode: UInt16, isRepeat: Bool) {
        guard before != after else { return }
        if var group = keyboardNudgeGroup, group.index == index, redoStack.isEmpty,
           timestamp >= group.lastTimestamp,
           (timestamp - group.lastTimestamp <= 0.35 || (isRepeat && keyCode == group.lastKeyCode)),
           group.after == before,
           let last = undoStack.last,
           case let .replaced(lastIndex, first, previous) = last,
           lastIndex == index, first == group.before, previous == before {
            if group.before == after {
                undoStack.removeLast()
                endKeyboardNudgeGroup()
            } else {
                undoStack[undoStack.count - 1] = .replaced(index: index, before: group.before, after: after)
                group.after = after
                group.lastTimestamp = timestamp
                group.lastKeyCode = keyCode
                keyboardNudgeGroup = group
            }
            onHistoryChange?()
            return
        }
        // The first real movement is immediately undoable. Repeats only
        // replace that one entry; no timer or uncommitted history is needed.
        recordHistory(.replaced(index: index, before: before, after: after))
        keyboardNudgeGroup = KeyboardNudgeGroup(index: index, before: before, after: after,
                                               lastTimestamp: timestamp, lastKeyCode: keyCode)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing else { return }
        setInteractionActive(true)
        if viewportMoveOriginal != nil {
            updateViewportMove(with: event)
            return
        }
        if let handle = viewportResizeHandle,
           let original = viewportResizeOriginal,
           let screenStart = viewportResizeScreenStart {
            guard let screenPoint = viewportPointer(for: event) else { return }
            let delta = CGPoint(x: screenPoint.x - screenStart.x, y: screenStart.y - screenPoint.y)
            setViewport(resizedViewport(original, moving: handle, delta: delta))
            return
        }
        let point = bounded(convert(event.locationInWindow, from: nil))
        if let index = resizingLineIndex,
           annotations.indices.contains(index),
           case let .line(start, end, color, width, arrow) = annotations[index] {
            let nextStart = resizingLineStartEndpoint ? point : start
            let nextEnd = resizingLineStartEndpoint ? end : point
            // Keep a visible last-valid arrow when an endpoint crosses its
            // opposite end; an empty path would become impossible to select.
            if arrow, hypot(nextEnd.x - nextStart.x, nextEnd.y - nextStart.y) <= 1 { return }
            let oldBounds = selectionDisplayBounds(at: index)
            annotations[index] = .line(nextStart, nextEnd, color, width, arrow)
            didTransformAnnotation = true
            invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
            return
        }
        if let index = resizingShapeIndex,
           let original = resizingShapeOriginal,
           let handle = resizingShapeHandle,
           annotations.indices.contains(index) {
            let oldBounds = selectionDisplayBounds(at: index)
            let originalRect = annotationGeometryBounds(original)
            let newRect = resizedRectangle(originalRect, moving: handle, to: point)
            annotations[index] = resizingAnnotation(original, from: originalRect, to: newRect)
            didTransformAnnotation = true
            invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
            return
        }
        if let index = movingAnnotationIndex,
           let original = movingAnnotationOriginal,
           let start = movingAnnotationStart,
           annotations.indices.contains(index) {
            let oldBounds = selectionDisplayBounds(at: index)
            let originalRect = annotationGeometryBounds(original)
            let delta = CGPoint(
                x: min(max(point.x - start.x, -originalRect.minX), max(-originalRect.minX, bounds.width - originalRect.maxX)),
                y: min(max(point.y - start.y, -originalRect.minY), max(-originalRect.minY, bounds.height - originalRect.maxY))
            )
            annotations[index] = translatedAnnotation(original, by: delta)
            didTransformAnnotation = abs(delta.x) + abs(delta.y) > 0.01
            invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
            return
        }
        if let index = resizingTextIndex,
           annotations.indices.contains(index),
           let originalSize = resizingTextOriginalSize,
           let originalLayoutWidth = resizingTextOriginalLayoutWidth,
           let startPoint = resizingTextStartPoint,
           case let .text(text, origin, color, _, _, _) = annotations[index] {
            let oldBounds = selectionDisplayBounds(at: index)
            let minimumWidth = min(36, max(1, originalLayoutWidth))
            // A short auto label must not jump to 36pt on first drag. A
            // cropped, partly off-screen label likewise retains its stored
            // width until the user actually changes it.
            let availableWidth = max(originalLayoutWidth, max(minimumWidth, bounds.width - origin.x))
            let horizontalDelta = point.x - startPoint.x
            let layoutWidth = min(
                availableWidth,
                max(minimumWidth, originalLayoutWidth + horizontalDelta)
            )
            let changedWidth = abs(horizontalDelta) > 0.5 && abs(layoutWidth - originalLayoutWidth) > 0.5
            let finalWidth = changedWidth ? layoutWidth : originalLayoutWidth
            let layoutMode: TextLayoutMode = changedWidth ? .fixed : (resizingTextOriginalLayoutMode ?? .auto)
            annotations[index] = .text(text, origin, color, originalSize, finalWidth, layoutMode)
            didTransformAnnotation = changedWidth
            invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
            window?.invalidateCursorRects(for: self)
            return
        }
        if let index = selectedAnnotationIndex,
           annotations.indices.contains(index),
           let movingTextStart,
           let movingTextOriginalPoint,
           case let .text(text, _, color, fontSize, layoutWidth, layoutMode) = annotations[index] {
            let oldBounds = selectionDisplayBounds(at: index)
            let size = textSize(text, color: color, fontSize: fontSize, layoutWidth: layoutWidth)
            let proposed = CGPoint(
                x: movingTextOriginalPoint.x + point.x - movingTextStart.x,
                y: movingTextOriginalPoint.y + point.y - movingTextStart.y
            )
            let destination = CGPoint(
                x: min(max(0, proposed.x), max(0, bounds.width - layoutWidth)),
                y: min(max(0, proposed.y), max(0, bounds.height - size.height))
            )
            annotations[index] = .text(text, destination, color, fontSize, layoutWidth, layoutMode)
            didTransformAnnotation = true
            invalidateTransition(from: oldBounds, to: selectionDisplayBounds(at: index))
            window?.invalidateCursorRects(for: self)
            return
        }
        let previousDraftRects = draftInvalidationRects()
        dragCurrent = point
        if tool == .pen,
           penPoints.last.map({ hypot(point.x - $0.x, point.y - $0.y) >= 0.75 }) ?? true {
            penPoints.append(point)
        }
        previousDraftRects.forEach(invalidateDisplay)
        invalidateDraft()
    }

    override func mouseUp(with event: NSEvent) {
        defer { setInteractionActive(false) }
        guard isEditing else { return }
        if let original = viewportMoveOriginal {
            // Commit the last displayed crop. Mouse-up must not move it.
            viewportMoveOriginal = nil
            viewportMoveScreenStart = nil
            if original != viewport { recordHistory(.viewport(before: original, after: viewport)) }
            window?.invalidateCursorRects(for: self)
            return
        }
        if let original = viewportResizeOriginal {
            viewportResizeHandle = nil
            viewportResizeOriginal = nil
            viewportResizeScreenStart = nil
            if original != viewport { recordHistory(.viewport(before: original, after: viewport)) }
            window?.invalidateCursorRects(for: self)
            return
        }
        if resizingLineIndex != nil || resizingShapeIndex != nil || movingAnnotationIndex != nil {
            resizingLineIndex = nil
            resizingShapeIndex = nil
            resizingShapeOriginal = nil
            resizingShapeHandle = nil
            movingAnnotationIndex = nil
            movingAnnotationOriginal = nil
            movingAnnotationStart = nil
            finishAnnotationTransform()
            window?.invalidateCursorRects(for: self)
            return
        }
        if resizingTextIndex != nil {
            resizingTextIndex = nil
            resizingTextOriginalSize = nil
            resizingTextOriginalLayoutWidth = nil
            resizingTextOriginalLayoutMode = nil
            resizingTextStartPoint = nil
            finishAnnotationTransform()
            return
        }
        if movingTextStart != nil {
            movingTextStart = nil
            movingTextOriginalPoint = nil
            finishAnnotationTransform()
            return
        }
        dragCurrent = bounded(convert(event.locationInWindow, from: nil))
        guard let start = dragStart, let end = dragCurrent else { return resetDraft() }
        let rect = normalizedRect(start, end)

        switch tool {
        case .move: break
        case .line: add(.line(start, end, strokeColor, strokeWidth, false))
        case .arrow where hypot(end.x - start.x, end.y - start.y) > 1:
            add(.line(start, end, strokeColor, strokeWidth, true))
        case .rectangle where rect.width > 2 && rect.height > 2: add(.rectangle(rect, strokeColor, strokeWidth))
        case .ellipse where rect.width > 2 && rect.height > 2: add(.ellipse(rect, strokeColor, strokeWidth))
        case .pen where penPoints.count > 1: add(.pen(penPoints, strokeColor, strokeWidth))
        case .mosaic where rect.width > 2 && rect.height > 2: add(.mosaic(rect))
        case .crop where rect.width > 4 && rect.height > 4: applyCrop(rect)
        case .text: beginInlineText(at: start)
        default: break
        }
        resetDraft()
    }

    private func beginInlineText(at point: CGPoint) {
        let lineHeight = InlineAnnotationTextView.fallbackLineHeight(
            for: NSFont.systemFont(ofSize: textFontSize, weight: .regular)
        )
        let minimumX = min(bounds.maxX, bounds.minX + 10)
        let maximumX = max(minimumX, bounds.maxX - 10 - max(2, textFontSize))
        let minimumY = min(bounds.maxY, bounds.minY + 6)
        // Reserve the same caret allowance used by the live layout, so an
        // empty first line at the bottom edge does not immediately overflow.
        let maximumY = max(minimumY, bounds.maxY - 6 - lineHeight - 2)
        // Resolve the initial caret position once. Later growth must not push
        // the text's origin left/up as its glass shell becomes larger.
        let anchor = CGPoint(x: min(max(point.x, minimumX), maximumX), y: min(max(point.y, minimumY), maximumY))
        beginInlineText(
            anchor: anchor,
            text: "",
            color: strokeColor,
            fontSize: textFontSize,
            layoutWidth: 8,
            layoutMode: .auto,
            editingIndex: nil
        )
    }

    private func beginInlineText(editingTextAt index: Int) {
        guard annotations.indices.contains(index),
              case let .text(text, point, color, fontSize, layoutWidth, layoutMode) = annotations[index] else { return }
        beginInlineText(
            anchor: point,
            text: text,
            color: color,
            fontSize: fontSize,
            layoutWidth: layoutWidth,
            layoutMode: layoutMode,
            editingIndex: index
        )
    }

    private func beginInlineText(
        anchor: CGPoint,
        text: String,
        color: NSColor,
        fontSize: CGFloat,
        layoutWidth: CGFloat,
        layoutMode: TextLayoutMode,
        editingIndex: Int?
    ) {
        endKeyboardNudgeGroup()
        updateHoveredAnnotation(nil)
        commitInlineText()

        let initialWidth = max(1, layoutWidth)
        let initialHeight = InlineAnnotationTextView.fallbackLineHeight(
            for: NSFont.systemFont(ofSize: fontSize, weight: .regular)
        ) + 2
        let initialFrame = NSRect(x: anchor.x - 10, y: anchor.y - 6, width: initialWidth + 20, height: initialHeight + 12)
        let (container, host) = makeInlineTextContainer(frame: initialFrame)
        let textView = InlineAnnotationTextView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight))
        // The canvas owns the document geometry. Neither NSClipView nor a
        // delayed glass-content layout may resize the document a second time.
        textView.autoresizingMask = []
        configureInlineTypography(textView, color: color, fontSize: fontSize)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: initialWidth, height: .greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.commitInlineText(activateMoveTool: true) }
        textView.onCancel = { [weak self] in self?.cancelInlineText() }

        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 6, width: initialWidth, height: initialHeight))
        scrollView.autoresizingMask = []
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        inlineTextView = textView
        inlineTextContainer = container
        inlineTextHost = host
        inlineTextScrollView = scrollView
        inlineTextAnchor = anchor
        inlineTextPoint = anchor
        inlineTextLayoutWidth = layoutWidth
        inlineTextLayoutMode = layoutMode
        inlineTextFontSize = fontSize
        inlineEditingTextIndex = editingIndex
        selectedAnnotationIndex = nil
        textFontSize = fontSize
        onTextSizeChangeRequest?(.nearest(to: fontSize))
        textView.onLiveTextChange = { [weak self, weak textView] in
            guard let self, let textView, self.inlineTextView === textView,
                  !self.isFinishingInlineText else { return }
            self.resizeInlineTextEditor()
            self.onHistoryChange?()
        }
        host.addSubview(scrollView)
        addSubview(container)
        resizeInlineTextEditor(preferredLayoutWidth: editingIndex == nil ? nil : layoutWidth)
        invalidateDisplay(container.frame)
        if let editingIndex { invalidateDisplay(selectionDisplayBounds(at: editingIndex)) }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        onHistoryChange?()
    }

    private func makeInlineTextContainer(frame: NSRect) -> (NSView, NSView) {
        // Glass is a passive background only. The ordinary container/host
        // own all input geometry independently of NSGlassEffectView's native
        // content-view layout, including delayed layout during composition.
        let container = NSView(frame: frame)
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.autoresizingMask = []
        let background = InlineTextSurfaceBackground(frame: NSRect(origin: .zero, size: frame.size))
        background.autoresizingMask = [.width, .height]
        let glassHost = NSView(frame: background.bounds)
        let glass = CaptureAppearance.surfaceBackground(
            frame: background.bounds,
            host: glassHost,
            cornerRadius: CaptureAppearance.inputCornerRadius
        )
        glass.autoresizingMask = [.width, .height]
        background.addSubview(glass)
        container.addSubview(background)
        container.addSubview(host)
        return (container, host)
    }

    private func configureInlineTypography(_ textView: NSTextView, color: NSColor, fontSize: CGFloat) {
        // The editor and bitmap export share the same native font, paragraph
        // wrapping and color. Input-method marked text remains AppKit-owned.
        let attributes = textAttributes(color: color, fontSize: fontSize)
        textView.font = attributes[.font] as? NSFont
        textView.textColor = color
        textView.insertionPointColor = color
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
        textView.usesAdaptiveColorMappingForDarkAppearance = false
    }

    private func resizeInlineTextEditor(preferredLayoutWidth: CGFloat? = nil) {
        guard !isResizingInlineText,
              let textView = inlineTextView,
              let container = inlineTextContainer,
              let host = inlineTextHost,
              let scrollView = inlineTextScrollView,
              let fontSize = inlineTextFontSize else { return }
        isResizingInlineText = true
        defer { isResizingInlineText = false }

        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 6
        let anchor = inlineTextPoint ?? inlineTextAnchor ?? .zero
        let layoutWidth: CGFloat
        if let preferredLayoutWidth {
            // Merely reopening text must preserve its existing layout, even
            // when a subsequent crop leaves its original origin off screen.
            layoutWidth = max(1, preferredLayoutWidth)
        } else if inlineTextLayoutMode == .fixed {
            layoutWidth = max(1, inlineTextLayoutWidth ?? 8)
        } else {
            layoutWidth = automaticTextLayoutWidth(for: textView, anchor: anchor)
        }

        let lineHeight = textView.nativeLineHeight(for: NSFont.systemFont(ofSize: fontSize, weight: .regular))
        let maximumVisibleHeight = max(1, bounds.maxY - anchor.y - verticalPadding)
        let containerOrigin = CGPoint(x: anchor.x - horizontalPadding, y: anchor.y - verticalPadding)
        func layoutSurface(visibleContentHeight: CGFloat, tileForScrollerChange: Bool = false) {
            let containerFrame = NSRect(
                origin: containerOrigin,
                size: CGSize(width: layoutWidth + horizontalPadding * 2,
                             height: visibleContentHeight + verticalPadding * 2)
            )
            if container.frame != containerFrame { container.frame = containerFrame }
            // Only the passive background can autoresize. Give the ordinary
            // host/clip/document one explicit geometry, independent of glass.
            let hostFrame = NSRect(origin: .zero, size: containerFrame.size)
            if host.frame != hostFrame { host.frame = hostFrame }
            let scrollFrame = NSRect(x: horizontalPadding, y: verticalPadding,
                                     width: layoutWidth, height: visibleContentHeight)
            let scrollFrameChanged = scrollView.frame != scrollFrame
            if scrollFrameChanged { scrollView.frame = scrollFrame }
            if scrollFrameChanged || tileForScrollerChange { scrollView.tile() }
        }

        // Settle the final width of every containing view before measuring.
        // Keep the current positive height until actual layout is known, so
        // a default-line fallback cannot grow/shrink the shell on every key.
        layoutSurface(visibleContentHeight: min(max(1, scrollView.frame.height), maximumVisibleHeight))
        // Measure in the final live width only. Never widen/reset the live
        // text container to measure text: that would move IME caret anchors.
        if abs(textView.frame.width - layoutWidth) > 0.25 {
            textView.setFrameSize(NSSize(width: layoutWidth, height: max(1, textView.frame.height)))
        }
        if let textContainer = textView.textContainer,
           abs(textContainer.containerSize.width - layoutWidth) > 0.25 {
            textContainer.containerSize = NSSize(width: layoutWidth, height: .greatestFiniteMagnitude)
        }
        let measuredHeight: CGFloat
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).maxY
            let extraHeight = layoutManager.extraLineFragmentTextContainer === textContainer
                ? layoutManager.extraLineFragmentRect.maxY : 0
            measuredHeight = max(usedHeight, extraHeight)
        } else {
            measuredHeight = textSize(
                textView.string.isEmpty ? " " : textView.string,
                color: textView.textColor ?? strokeColor,
                fontSize: fontSize,
                layoutWidth: layoutWidth
            ).height
        }
        // A font-wide glyph bounding box is not a text line. Prefer the live
        // typesetter's actual extent, including the empty trailing caret line.
        let fullContentHeight = ceil(measuredHeight > 0 ? measuredHeight : lineHeight) + 2
        let visibleContentHeight = min(fullContentHeight, maximumVisibleHeight)
        let needsVerticalScroller = fullContentHeight > visibleContentHeight + 0.5
        let scrollerChanged = scrollView.hasVerticalScroller != needsVerticalScroller
        if scrollerChanged { scrollView.hasVerticalScroller = needsVerticalScroller }
        layoutSurface(visibleContentHeight: visibleContentHeight, tileForScrollerChange: scrollerChanged)
        let documentSize = NSSize(width: layoutWidth, height: fullContentHeight)
        if textView.frame.size != documentSize {
            textView.setFrameSize(documentSize)
        }
        inlineTextLayoutWidth = layoutWidth
        let clipView = scrollView.contentView
        func constrainClipPosition() {
            var constrainedBounds = clipView.constrainBoundsRect(clipView.bounds)
            // There is no horizontal scrolling: wrapping owns overflow. In
            // particular, discard a narrow preedit layout's old x offset.
            constrainedBounds.origin.x = 0
            if clipView.bounds.origin != constrainedBounds.origin {
                clipView.scroll(to: constrainedBounds.origin)
                scrollView.reflectScrolledClipView(clipView)
            }
        }
        constrainClipPosition()
        textView.scrollRangeToVisible(textView.selectedRange())
        constrainClipPosition()
        textView.inputContext?.invalidateCharacterCoordinates()
    }

    private func automaticTextLayoutWidth(for textView: InlineAnnotationTextView, anchor: CGPoint) -> CGFloat {
        let maximumWidth = max(1, bounds.maxX - anchor.x - 10)
        let inheritedFont = textView.font
            ?? NSFont.systemFont(ofSize: inlineTextFontSize ?? textFontSize, weight: .regular)
        let naturalWidth = textView.measuredNaturalWidth(maximumWidth: maximumWidth, fallbackFont: inheritedFont)
        return min(maximumWidth, max(min(8, maximumWidth), naturalWidth))
    }

    private func automaticTextLayoutWidth(_ text: String, color: NSColor, fontSize: CGFloat, anchor: CGPoint) -> CGFloat {
        let maximumWidth = max(1, bounds.maxX - anchor.x - 10)
        let naturalWidth = text.isEmpty ? 8 : naturalTextWidth(text, color: color, fontSize: fontSize)
        return min(maximumWidth, max(min(8, maximumWidth), ceil(naturalWidth)))
    }

    private func naturalTextWidth(_ text: String, color: NSColor, fontSize: CGFloat) -> CGFloat {
        let lines = text.components(separatedBy: .newlines)
        return lines.reduce(CGFloat.zero) { width, line in
            let candidate = line.isEmpty ? " " : line
            return max(width, ceil(candidate.size(withAttributes: textAttributes(color: color, fontSize: fontSize)).width) + 2)
        }
    }

    private func commitInlineText(activateMoveTool: Bool = false) {
        finishInlineText(shouldCommit: true, activateMoveTool: activateMoveTool)
    }

    private func cancelInlineText() {
        finishInlineText(shouldCommit: false, activateMoveTool: false)
    }

    private func finishInlineText(shouldCommit: Bool, activateMoveTool: Bool) {
        guard !isFinishingInlineText, let textView = inlineTextView else { return }
        isFinishingInlineText = true
        defer { isFinishingInlineText = false }

        textView.onLiveTextChange = nil
        textView.delegate = nil
        textView.onCommit = nil
        textView.onCancel = nil
        let text = textView.string
        let point = inlineTextPoint ?? textView.frame.origin
        let color = textView.textColor ?? strokeColor
        let fontSize = inlineTextFontSize ?? textFontSize
        var layoutWidth = inlineTextLayoutWidth ?? 8
        let layoutMode = inlineTextLayoutMode ?? .auto
        let editingIndex = inlineEditingTextIndex
        let previousTextBounds = editingIndex.flatMap { selectionDisplayBounds(at: $0) }
        if let editingIndex, annotations.indices.contains(editingIndex),
           case let .text(oldText, _, oldColor, oldSize, oldWidth, oldMode) = annotations[editingIndex],
           oldText == text, oldColor.isEqual(color), abs(oldSize - fontSize) < 0.01,
           oldMode == layoutMode {
            // Reopening or undoing all live text edits must not rewrite a
            // previously cropped annotation's stored width behind the user.
            layoutWidth = oldWidth
        }
        inlineTextView = nil
        let container = inlineTextContainer
        inlineTextContainer = nil
        inlineTextHost = nil
        inlineTextScrollView = nil
        inlineTextPoint = nil
        inlineTextAnchor = nil
        inlineTextLayoutWidth = nil
        inlineTextLayoutMode = nil
        inlineTextFontSize = nil
        inlineEditingTextIndex = nil

        if window?.firstResponder === textView {
            window?.makeFirstResponder(self)
        }
        textView.removeFromSuperview()
        container?.removeFromSuperview()
        invalidateDisplay(container?.frame)

        if shouldCommit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let annotation = Annotation.text(text, point, color, fontSize, layoutWidth, layoutMode)
            if let editingIndex, annotations.indices.contains(editingIndex) {
                let previous = annotations[editingIndex]
                let unchanged: Bool
                if case let .text(oldText, oldPoint, oldColor, oldSize, oldWidth, oldMode) = previous {
                    unchanged = oldText == text && oldPoint == point
                        && oldColor.isEqual(color) && abs(oldSize - fontSize) < 0.01
                        && abs(oldWidth - layoutWidth) < 0.01 && oldMode == layoutMode
                } else {
                    unchanged = false
                }
                if !unchanged {
                    annotations[editingIndex] = annotation
                    recordHistory(.replaced(index: editingIndex, before: previous, after: annotation))
                }
                selectedAnnotationIndex = editingIndex
                invalidateTransition(from: previousTextBounds, to: selectionDisplayBounds(at: editingIndex))
            } else {
                add(annotation)
            }
            if activateMoveTool {
                onToolChangeRequest?(.move)
            }
        } else if let editingIndex, annotations.indices.contains(editingIndex) {
            if shouldCommit {
                let previous = annotations.remove(at: editingIndex)
                recordHistory(.removed(index: editingIndex, annotation: previous))
                selectedAnnotationIndex = nil
            } else {
                selectedAnnotationIndex = editingIndex
            }
            invalidateTransition(from: previousTextBounds, to: selectedAnnotationIndex.flatMap { selectionDisplayBounds(at: $0) })
        }
        notifySelectionContextChange()
        onHistoryChange?()
    }

    func textDidChange(_ notification: Notification) {
        guard let inlineTextView, notification.object as? NSTextView === inlineTextView,
              !inlineTextView.isPerformingNativeTextMutation else { return }
        resizeInlineTextEditor()
        onHistoryChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let inlineTextView, textView === inlineTextView else { return false }

        let isLineBreakCommand = commandSelector == #selector(NSResponder.insertLineBreak(_:))
        let isReturnCommand = commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        guard isReturnCommand || isLineBreakCommand else { return false }

        if inlineTextView.isHandlingMarkedTextReturn || inlineTextView.hasMarkedText() {
            // This Return belongs to an input method candidate. Consume any
            // newline command it leaves behind without closing the editor.
            return true
        }
        if isLineBreakCommand || inlineTextView.isHandlingModifiedReturn { return false }

        commitInlineText(activateMoveTool: true)
        return true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inlineTextView else { return }
        commitInlineText(activateMoveTool: true)
    }

    @discardableResult
    private func add(_ annotation: Annotation) -> Int {
        let index = annotations.count
        annotations.append(annotation)
        recordHistory(.added(index: index, annotation: annotation))
        selectedAnnotationIndex = index
        invalidateDisplay(selectionDisplayBounds(at: index))
        return index
    }

    private func recordHistory(_ entry: AnnotationHistoryEntry) {
        endKeyboardNudgeGroup()
        // A click, drag back to the origin or unchanged edit must neither
        // occupy an undo slot nor erase a still-valid redo branch.
        if case let .replaced(_, before, after) = entry, before == after { return }
        if case let .viewport(before, after) = entry, before == after { return }
        undoStack.append(entry)
        // Only geometry/text is retained. Capping the session history bounds
        // memory during prolonged editing without creating any disk history.
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack.removeAll()
        onHistoryChange?()
    }

    private func annotationTitle(_ annotation: Annotation) -> String {
        switch annotation {
        case let .line(_, _, _, _, arrow): return arrow ? "箭头" : "直线"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    private func historyActionTitle(_ entry: AnnotationHistoryEntry) -> String {
        switch entry {
        case let .added(_, annotation): return "添加" + annotationTitle(annotation)
        case let .removed(_, annotation): return "删除" + annotationTitle(annotation)
        case let .viewport(before, after):
            if before.size == after.size { return "移动截图范围" }
            return before.contains(after) ? "裁剪" : "调整截图范围"
        case let .replaced(_, before, after):
            let name = annotationTitle(after)
            switch (before, after) {
            case let (.text(oldText, oldPoint, oldColor, oldSize, oldWidth, oldMode), .text(text, point, color, size, width, mode)):
                if oldText != text { return "编辑文字" }
                if oldSize != size || oldWidth != width || oldMode != mode { return "调整文字" }
                if !oldColor.isEqual(color) { return "修改文字样式" }
                return oldPoint != point ? "移动文字" : "编辑文字"
            case let (.line(a, b, oldColor, oldWidth, _), .line(c, d, color, width, _)):
                if !oldColor.isEqual(color) || oldWidth != width { return "修改" + name + "样式" }
                let sameDelta = abs((c.x - a.x) - (d.x - b.x)) < 0.01
                    && abs((c.y - a.y) - (d.y - b.y)) < 0.01
                return (sameDelta ? "移动" : "调整") + name
            case let (.rectangle(oldRect, oldColor, oldWidth), .rectangle(rect, color, width)),
                 let (.ellipse(oldRect, oldColor, oldWidth), .ellipse(rect, color, width)):
                if !oldColor.isEqual(color) || oldWidth != width { return "修改" + name + "样式" }
                return (oldRect.size == rect.size ? "移动" : "调整") + name
            case let (.mosaic(oldRect), .mosaic(rect)):
                return (oldRect.size == rect.size ? "移动" : "调整") + name
            case let (.pen(oldPoints, oldColor, oldWidth), .pen(points, color, width)):
                if !oldColor.isEqual(color) || oldWidth != width { return "修改画笔样式" }
                guard oldPoints.count == points.count, let a = oldPoints.first, let b = points.first else { return "调整画笔" }
                let dx = b.x - a.x
                let dy = b.y - a.y
                let moved = zip(oldPoints, points).allSatisfy { old, new in
                    abs(new.x - old.x - dx) < 0.01 && abs(new.y - old.y - dy) < 0.01
                }
                return moved ? "移动画笔" : "调整画笔"
            default: return "编辑" + name
            }
        }
    }

    @objc func undo(_ sender: Any?) { undoLast() }
    @objc func redo(_ sender: Any?) { redoLast() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            (item as? NSMenuItem)?.title = undoTitle
            return canUndo
        }
        if item.action == #selector(redo(_:)) {
            (item as? NSMenuItem)?.title = redoTitle
            return canRedo
        }
        return true
    }

    func deleteSelectedAnnotation() {
        endKeyboardNudgeGroup()
        guard isEditing, !isEnteringText,
              let index = selectedAnnotationIndex,
              annotations.indices.contains(index) else { return }
        updateHoveredAnnotation(nil)
        let oldBounds = selectionDisplayBounds(at: index)
        let annotation = annotations.remove(at: index)
        selectedAnnotationIndex = nil
        recordHistory(.removed(index: index, annotation: annotation))
        invalidateDisplay(oldBounds)
    }

    func undoLast() {
        defer { onHistoryChange?() }
        if let inlineTextView {
            if inlineTextView.undoManager?.canUndo == true { inlineTextView.undoManager?.undo() }
            focusInlineText()
            return
        }
        finishGeometryGesture()
        selectedAnnotationIndex = nil
        guard let entry = undoStack.popLast() else { return }
        switch entry {
        case let .added(index, _):
            guard annotations.indices.contains(index) else {
                undoStack.append(entry)
                return
            }
            let current = annotations.remove(at: index)
            redoStack.append(.added(index: index, annotation: current))
        case let .replaced(index, before, _):
            guard annotations.indices.contains(index) else {
                undoStack.append(entry)
                return
            }
            let current = annotations[index]
            annotations[index] = before
            redoStack.append(.replaced(index: index, before: before, after: current))
        case let .removed(index, annotation):
            annotations.insert(annotation, at: min(max(0, index), annotations.count))
            redoStack.append(entry)
        case let .viewport(before, _):
            setViewport(before)
            redoStack.append(entry)
        }
        needsDisplay = true
    }

    func redoLast() {
        defer { onHistoryChange?() }
        if let inlineTextView {
            if inlineTextView.undoManager?.canRedo == true { inlineTextView.undoManager?.redo() }
            focusInlineText()
            return
        }
        finishGeometryGesture()
        selectedAnnotationIndex = nil
        guard let entry = redoStack.popLast() else { return }
        switch entry {
        case let .added(index, annotation):
            let insertionIndex = min(max(0, index), annotations.count)
            annotations.insert(annotation, at: insertionIndex)
            undoStack.append(.added(index: insertionIndex, annotation: annotation))
        case let .replaced(index, _, after):
            guard annotations.indices.contains(index) else {
                redoStack.append(entry)
                return
            }
            let current = annotations[index]
            annotations[index] = after
            undoStack.append(.replaced(index: index, before: current, after: after))
        case let .removed(index, _):
            guard annotations.indices.contains(index) else { return }
            annotations.remove(at: index)
            undoStack.append(entry)
        case let .viewport(_, after):
            setViewport(after)
            undoStack.append(entry)
        }
        needsDisplay = true
    }

    private func applyCrop(_ rect: CGRect) {
        let before = viewport
        let proposed = rect.offsetBy(dx: viewport.minX, dy: viewport.minY)
        setViewport(proposed)
        if before != viewport { recordHistory(.viewport(before: before, after: viewport)) }
    }

    /// Moving/resizing always refers back to the original frozen capture.
    /// Annotations stay anchored to that source while its viewport changes.
    private func setViewport(_ proposed: CGRect) {
        endKeyboardNudgeGroup()
        let sourceBounds = CGRect(origin: .zero, size: sourcePointSize)
        let clipped = proposed.standardized.intersection(sourceBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        let scaleX = CGFloat(sourceImage.width) / sourcePointSize.width
        let scaleY = CGFloat(sourceImage.height) / sourcePointSize.height
        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        func pixelEdge(_ value: CGFloat, upper: Bool) -> CGFloat {
            let nearest = value.rounded()
            // Source-pixel-aligned points may acquire tiny division noise.
            // Avoid growing a one-pixel border when moving or undoing them.
            if abs(value - nearest) < 0.000001 { return nearest }
            return upper ? ceil(value) : floor(value)
        }
        let minX = pixelEdge(clipped.minX * scaleX, upper: false)
        let minY = pixelEdge(clipped.minY * scaleY, upper: false)
        let maxX = pixelEdge(clipped.maxX * scaleX, upper: true)
        let maxY = pixelEdge(clipped.maxY * scaleY, upper: true)
        let crop = CGRect(
            x: minX, y: minY, width: maxX - minX, height: maxY - minY
        ).integral.intersection(imageBounds)
        let nextViewport = CGRect(x: crop.minX / scaleX, y: crop.minY / scaleY, width: crop.width / scaleX, height: crop.height / scaleY)
        guard nextViewport != viewport,
              let cropped = sourceImage.cropping(to: crop) else { return }
        updateHoveredAnnotation(nil)
        let previous = viewport
        viewport = nextViewport
        let offset = CGPoint(x: previous.minX - viewport.minX, y: previous.minY - viewport.minY)
        annotations = annotations.map { translatedAnnotation($0, by: offset) }
        imagePointSize = CGSize(width: crop.width / scaleX, height: crop.height / scaleY)
        baseImage = cropped
        displayImage = NSImage(cgImage: cropped, size: imagePointSize)
        if frame.size != imagePointSize { frame.size = imagePointSize }
        needsDisplay = true
        if let onViewportChange {
            onViewportChange(previous, viewport)
        } else {
            onSizeChange?(imagePointSize)
        }
        window?.invalidateCursorRects(for: self)
    }

    private func resetDraft() {
        let invalidationRects = draftInvalidationRects()
        dragStart = nil
        dragCurrent = nil
        penPoints.removeAll()
        invalidationRects.forEach(invalidateDisplay)
    }

    private func finishGeometryGesture(preservingKeyboardNudge: Bool = false) {
        if !preservingKeyboardNudge { endKeyboardNudgeGroup() }
        updateHoveredAnnotation(nil)
        if let original = viewportMoveOriginal ?? viewportResizeOriginal, original != viewport {
            recordHistory(.viewport(before: original, after: viewport))
        }
        viewportResizeHandle = nil
        viewportResizeOriginal = nil
        viewportResizeScreenStart = nil
        viewportMoveOriginal = nil
        viewportMoveScreenStart = nil
        if transformingAnnotationIndex != nil { finishAnnotationTransform() }
        movingTextStart = nil
        movingTextOriginalPoint = nil
        resizingTextIndex = nil
        resizingTextOriginalSize = nil
        resizingTextOriginalLayoutWidth = nil
        resizingTextOriginalLayoutMode = nil
        resizingTextStartPoint = nil
        movingAnnotationIndex = nil
        movingAnnotationStart = nil
        movingAnnotationOriginal = nil
        resizingShapeIndex = nil
        resizingShapeOriginal = nil
        resizingShapeHandle = nil
        resizingLineIndex = nil
        resetDraft()
        setInteractionActive(false)
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func toolMatchesAnnotation(_ annotation: Annotation) -> Bool {
        switch (tool, annotation) {
        case (.text, .text), (.arrow, .line(_, _, _, _, true)),
             (.line, .line(_, _, _, _, false)), (.rectangle, .rectangle),
             (.ellipse, .ellipse), (.pen, .pen), (.mosaic, .mosaic): return true
        default: return false
        }
    }

    private func translatedAnnotation(_ annotation: Annotation, by delta: CGPoint) -> Annotation {
        func point(_ value: CGPoint) -> CGPoint { CGPoint(x: value.x + delta.x, y: value.y + delta.y) }
        switch annotation {
        case let .line(a, b, color, width, arrow): return .line(point(a), point(b), color, width, arrow)
        case let .rectangle(rect, color, width): return .rectangle(rect.offsetBy(dx: delta.x, dy: delta.y), color, width)
        case let .ellipse(rect, color, width): return .ellipse(rect.offsetBy(dx: delta.x, dy: delta.y), color, width)
        case let .pen(points, color, width): return .pen(points.map(point), color, width)
        case let .text(text, origin, color, fontSize, layoutWidth, layoutMode): return .text(text, point(origin), color, fontSize, layoutWidth, layoutMode)
        case let .mosaic(rect): return .mosaic(rect.offsetBy(dx: delta.x, dy: delta.y))
        }
    }

    private func annotationGeometryBounds(_ annotation: Annotation) -> CGRect {
        switch annotation {
        case let .line(start, end, _, width, arrow):
            guard arrow else { return normalizedRect(start, end) }
            let path = arrowPath(from: start, to: end, width: width)
            return path.isEmpty ? normalizedRect(start, end) : path.bounds
        case let .rectangle(rect, _, _), let .ellipse(rect, _, _), let .mosaic(rect): return rect
        case let .pen(points, _, _):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        case .text: return annotationCoreBounds(annotation)
        }
    }

    private func resizingAnnotation(_ annotation: Annotation, from original: CGRect, to destination: CGRect) -> Annotation {
        switch annotation {
        case let .rectangle(_, color, width): return .rectangle(destination, color, width)
        case let .ellipse(_, color, width): return .ellipse(destination, color, width)
        case .mosaic: return .mosaic(destination)
        case let .pen(points, color, width):
            let resized = points.map { point in
                CGPoint(
                    x: destination.minX + (point.x - original.minX) / max(0.01, original.width) * destination.width,
                    y: destination.minY + (point.y - original.minY) / max(0.01, original.height) * destination.height
                )
            }
            return .pen(resized, color, width)
        default: return annotation
        }
    }

    private func viewportResizeHandles() -> [(ViewportResizeHandle, CGRect)] {
        let x0: CGFloat = min(4, bounds.width / 2)
        let y0: CGFloat = min(4, bounds.height / 2)
        let x1 = max(x0, bounds.maxX - 4)
        let y1 = max(y0, bounds.maxY - 4)
        let centers: [(ViewportResizeHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: x0, y: y0)), (.top, CGPoint(x: bounds.midX, y: y0)),
            (.topRight, CGPoint(x: x1, y: y0)), (.right, CGPoint(x: x1, y: bounds.midY)),
            (.bottomRight, CGPoint(x: x1, y: y1)), (.bottom, CGPoint(x: bounds.midX, y: y1)),
            (.bottomLeft, CGPoint(x: x0, y: y1)), (.left, CGPoint(x: x0, y: bounds.midY))
        ]
        return centers.map { ($0.0, CGRect(x: $0.1.x - 4, y: $0.1.y - 4, width: 8, height: 8)) }
    }

    private func viewportResizeHandle(at point: CGPoint) -> ViewportResizeHandle? {
        if let handle = viewportResizeHandles().first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(point) })?.0 {
            return handle
        }
        let slop: CGFloat = 6
        if point.x <= bounds.minX + slop { return .left }
        if point.x >= bounds.maxX - slop { return .right }
        if point.y <= bounds.minY + slop { return .top }
        if point.y >= bounds.maxY - slop { return .bottom }
        return nil
    }

    private func viewportEdgeCursorRects() -> [CGRect] {
        let slop: CGFloat = 6
        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(slop, bounds.height)),
            CGRect(x: bounds.minX, y: max(bounds.minY, bounds.maxY - slop), width: bounds.width, height: min(slop, bounds.height)),
            CGRect(x: bounds.minX, y: bounds.minY, width: min(slop, bounds.width), height: bounds.height),
            CGRect(x: max(bounds.minX, bounds.maxX - slop), y: bounds.minY, width: min(slop, bounds.width), height: bounds.height)
        ]
    }

    private func drawViewportHandles() {
        let emphasized = viewportResizeHandle ?? hoveredViewportHandle
        for (handle, rect) in viewportResizeHandles() {
            if handle == emphasized {
                drawResizeHandle(rect)
            } else {
                switch handle {
                case .topLeft, .topRight, .bottomLeft, .bottomRight:
                    let dot = rect.insetBy(dx: 2, dy: 2)
                    NSColor.white.withAlphaComponent(0.7).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    CaptureAppearance.selectionDarkOutline.withAlphaComponent(0.6).setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.4, dy: 0.4))
                    ring.lineWidth = 0.8
                    ring.stroke()
                default: break
                }
            }
        }
    }

    private func resizedViewport(_ original: CGRect, moving handle: ViewportResizeHandle, delta: CGPoint) -> CGRect {
        let minimumWidth = min(24, sourcePointSize.width)
        let minimumHeight = min(24, sourcePointSize.height)
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(max(0, original.minX + delta.x), original.maxX - minimumWidth)
        case .topRight, .right, .bottomRight: maxX = max(min(sourcePointSize.width, original.maxX + delta.x), original.minX + minimumWidth)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(max(0, original.minY + delta.y), original.maxY - minimumHeight)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(min(sourcePointSize.height, original.maxY + delta.y), original.minY + minimumHeight)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizedRectangle(
        _ original: CGRect,
        moving handle: RectangleResizeHandle,
        to point: CGPoint
    ) -> CGRect {
        let minimumSize: CGFloat = 8
        var movingPoint = bounded(point)
        let opposite: CGPoint
        switch handle {
        case .topLeft:
            opposite = CGPoint(x: original.maxX, y: original.maxY)
            movingPoint.x = min(movingPoint.x, opposite.x - minimumSize)
            movingPoint.y = min(movingPoint.y, opposite.y - minimumSize)
        case .topRight:
            opposite = CGPoint(x: original.minX, y: original.maxY)
            movingPoint.x = max(movingPoint.x, opposite.x + minimumSize)
            movingPoint.y = min(movingPoint.y, opposite.y - minimumSize)
        case .bottomRight:
            opposite = CGPoint(x: original.minX, y: original.minY)
            movingPoint.x = max(movingPoint.x, opposite.x + minimumSize)
            movingPoint.y = max(movingPoint.y, opposite.y + minimumSize)
        case .bottomLeft:
            opposite = CGPoint(x: original.maxX, y: original.minY)
            movingPoint.x = min(movingPoint.x, opposite.x - minimumSize)
            movingPoint.y = max(movingPoint.y, opposite.y + minimumSize)
        }
        return normalizedRect(opposite, movingPoint)
    }

    private func beginAnnotationTransform(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        transformingAnnotationIndex = index
        transformingAnnotationOriginal = annotations[index]
        didTransformAnnotation = false
    }

    private func finishAnnotationTransform() {
        defer {
            transformingAnnotationIndex = nil
            transformingAnnotationOriginal = nil
            didTransformAnnotation = false
        }
        guard didTransformAnnotation,
              let index = transformingAnnotationIndex,
              let before = transformingAnnotationOriginal,
              annotations.indices.contains(index) else { return }
        let after = annotations[index]
        recordHistory(.replaced(index: index, before: before, after: after))
        invalidateDisplay(selectionDisplayBounds(at: index))
    }

    private func invalidateDisplay(_ rect: CGRect?) {
        guard let rect else { return }
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        setNeedsDisplay(clipped)
    }

    private func invalidateTransition(from oldRect: CGRect?, to newRect: CGRect?) {
        invalidateDisplay(oldRect)
        invalidateDisplay(newRect)
    }

    private func invalidateDraft() {
        draftInvalidationRects().forEach(invalidateDisplay)
    }

    private func draftInvalidationRects(for drawingTool: EditorTool? = nil) -> [CGRect] {
        guard let start = dragStart, let end = dragCurrent else { return [] }
        let drawingTool = drawingTool ?? tool
        let padding = max(5, strokeWidth + 3)
        if drawingTool == .arrow {
            let path = arrowPath(from: start, to: end, width: strokeWidth)
            // A mouse-down (or a drag back to its origin) has no silhouette.
            // NSBezierPath.bounds raises on an empty path. Do not let the old
            // draft lookup abort mouseDragged before it updates the endpoint.
            guard !path.isEmpty else { return [] }
            return [path.bounds.insetBy(dx: -2, dy: -2)]
        }
        if drawingTool == .rectangle || drawingTool == .crop {
            let rect = normalizedRect(start, end)
            guard rect.width > 2, rect.height > 2 else { return [] }
            return borderInvalidationRects(for: rect, padding: padding)
        }
        if drawingTool == .pen, let first = penPoints.first {
            let bounds = penPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
            return [bounds.insetBy(dx: -padding, dy: -padding)]
        }
        return [normalizedRect(start, end).insetBy(dx: -padding, dy: -padding)]
    }

    private func borderInvalidationRects(for rect: CGRect, padding: CGFloat) -> [CGRect] {
        let thickness = padding * 2
        return [
            CGRect(x: rect.minX - padding, y: rect.minY - padding, width: rect.width + padding * 2, height: thickness),
            CGRect(x: rect.minX - padding, y: rect.maxY - padding, width: rect.width + padding * 2, height: thickness),
            CGRect(x: rect.minX - padding, y: rect.minY + padding, width: thickness, height: max(0, rect.height - padding * 2)),
            CGRect(x: rect.maxX - padding, y: rect.minY + padding, width: thickness, height: max(0, rect.height - padding * 2))
        ]
    }

    private func drawDraft() {
        guard let start = dragStart, let end = dragCurrent else { return }
        if tool == .pen {
            drawAnnotation(.pen(penPoints, strokeColor, strokeWidth))
        } else if tool != .text {
            let rect = normalizedRect(start, end)
            switch tool {
            case .line: drawAnnotation(.line(start, end, strokeColor, strokeWidth, false))
            case .arrow: drawAnnotation(.line(start, end, strokeColor, strokeWidth, true))
            case .rectangle where rect.width > 2 && rect.height > 2:
                drawAnnotation(.rectangle(rect, strokeColor, strokeWidth))
            case .crop where rect.width > 2 && rect.height > 2:
                drawAnnotation(.rectangle(rect, CaptureAppearance.selectionColor, CaptureAppearance.selectionLineWidth))
            case .ellipse: drawAnnotation(.ellipse(rect, strokeColor, strokeWidth))
            case .mosaic: drawAnnotation(.mosaic(rect))
            default: break
            }
        }
    }

    private func drawAnnotation(_ annotation: Annotation) {
        switch annotation {
        case let .line(start, end, color, width, arrow):
            if arrow {
                drawFilledArrow(from: start, to: end, color: color, width: width)
            } else {
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = width
                path.lineCapStyle = .round
                path.move(to: start)
                path.line(to: end)
                path.stroke()
            }
        case let .rectangle(rect, color, width):
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: width, yRadius: width)
            path.lineWidth = width
            path.stroke()
        case let .ellipse(rect, color, width):
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = width
            path.stroke()
        case let .pen(points, color, width):
            guard let first = points.first else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            points.dropFirst().forEach { path.line(to: $0) }
            path.stroke()
        case let .text(text, point, color, fontSize, layoutWidth, _):
            let rect = textRect(
                text: text,
                point: point,
                color: color,
                fontSize: fontSize,
                layoutWidth: layoutWidth
            )
            text.draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textAttributes(color: color, fontSize: fontSize)
            )
        case let .mosaic(rect):
            drawMosaic(rect)
        }
    }

    private func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func textSize(
        _ text: String,
        color: NSColor,
        fontSize: CGFloat,
        layoutWidth: CGFloat
    ) -> CGSize {
        let key = TextMeasurementKey(text: text, fontSize: fontSize, layoutWidth: layoutWidth)
        if let cached = textMeasurements[key] { return cached }
        let measured = text.boundingRect(
            with: CGSize(width: max(1, layoutWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(color: color, fontSize: fontSize)
        )
        let size = CGSize(width: ceil(min(layoutWidth, measured.width)), height: ceil(measured.height))
        if textMeasurements.count >= 64 { textMeasurements.removeAll(keepingCapacity: true) }
        textMeasurements[key] = size
        return size
    }

    private func textRect(
        text: String,
        point: CGPoint,
        color: NSColor,
        fontSize: CGFloat,
        layoutWidth: CGFloat
    ) -> CGRect {
        let measured = textSize(text, color: color, fontSize: fontSize, layoutWidth: layoutWidth)
        return CGRect(
            origin: point,
            size: CGSize(width: max(1, layoutWidth), height: max(1, measured.height))
        )
    }

    private func textRect(at index: Int) -> CGRect? {
        guard annotations.indices.contains(index),
              case let .text(text, point, color, fontSize, layoutWidth, _) = annotations[index] else { return nil }
        return textRect(
            text: text,
            point: point,
            color: color,
            fontSize: fontSize,
            layoutWidth: layoutWidth
        )
    }

    private func textAnnotationIndex(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first { index in
            textRect(at: index)?.insetBy(dx: -6, dy: -5).contains(point) == true
        }
    }

    private func annotationIndex(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first { index in
            let annotation = annotations[index]
            guard annotationCoreBounds(annotation).insetBy(dx: -7, dy: -7).contains(point) else { return false }
            switch annotation {
            case let .line(start, end, _, width, arrow):
                if arrow {
                    let path = arrowPath(from: start, to: end, width: width)
                    if !path.isEmpty, path.contains(point) { return true }
                }
                return distance(from: point, toSegmentFrom: start, to: end) <= max(8, width * 0.75)
            case let .pen(points, _, width):
                return zip(points, points.dropFirst()).contains { start, end in
                    distance(from: point, toSegmentFrom: start, to: end) <= max(8, width * 0.75)
                }
            default: return true
            }
        }
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
    }

    private func annotationCoreBounds(_ annotation: Annotation) -> CGRect {
        switch annotation {
        case let .line(start, end, _, width, arrow):
            if arrow {
                let path = arrowPath(from: start, to: end, width: width)
                let rect = path.isEmpty ? normalizedRect(start, end) : path.bounds
                return rect.insetBy(dx: -1, dy: -1)
            }
            return normalizedRect(start, end).insetBy(dx: -max(2, width / 2), dy: -max(2, width / 2))
        case let .rectangle(rect, _, width), let .ellipse(rect, _, width):
            return rect.insetBy(dx: -max(1, width / 2), dy: -max(1, width / 2))
        case let .pen(points, _, width):
            guard let first = points.first else { return .zero }
            let rect = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
            return rect.insetBy(dx: -max(2, width / 2), dy: -max(2, width / 2))
        case let .text(text, point, color, fontSize, layoutWidth, _):
            return textRect(text: text, point: point, color: color, fontSize: fontSize, layoutWidth: layoutWidth)
        case let .mosaic(rect):
            return rect
        }
    }

    private func annotationDisplayBounds(_ annotation: Annotation) -> CGRect {
        annotationCoreBounds(annotation).insetBy(dx: -10, dy: -10)
    }

    private func selectionDisplayBounds(at index: Int) -> CGRect? {
        guard annotations.indices.contains(index) else { return nil }
        var rect = annotationCoreBounds(annotations[index]).insetBy(dx: -10, dy: -10)
        if let handle = textResizeHandleRect(at: index) {
            rect = rect.union(handle.insetBy(dx: -2, dy: -2))
        }
        for (_, handle) in rectangleResizeHandles(at: index) {
            rect = rect.union(handle.insetBy(dx: -2, dy: -2))
        }
        for (_, handle) in lineResizeHandles(at: index) {
            rect = rect.union(handle.insetBy(dx: -2, dy: -2))
        }
        return rect
    }

    private func drawAnnotationSelection() {
        guard let selectedAnnotationIndex,
              selectedAnnotationIndex != inlineEditingTextIndex,
              annotations.indices.contains(selectedAnnotationIndex) else { return }
        if case .line = annotations[selectedAnnotationIndex] {
            for (_, handle) in lineResizeHandles(at: selectedAnnotationIndex) { drawResizeHandle(handle) }
            return
        }
        if case .rectangle = annotations[selectedAnnotationIndex] {
            // The rectangle is already its own visual boundary. Showing a
            // second blue dashed outline makes it look like two stacked boxes;
            // compact corner handles are sufficient for resizing.
            for (_, handle) in rectangleResizeHandles(at: selectedAnnotationIndex) {
                drawResizeHandle(handle)
            }
            return
        }
        let rect = annotationCoreBounds(annotations[selectedAnnotationIndex]).insetBy(dx: -5, dy: -5)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        outline.lineJoinStyle = .round
        CaptureAppearance.selectionLightOutline.withAlphaComponent(0.82).setStroke()
        outline.lineWidth = 2.5
        outline.stroke()
        CaptureAppearance.selectionDarkOutline.withAlphaComponent(0.62).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        if let handle = textResizeHandleRect(at: selectedAnnotationIndex) {
            drawResizeHandle(handle)
        }
        for (_, handle) in rectangleResizeHandles(at: selectedAnnotationIndex) { drawResizeHandle(handle) }
    }

    private func drawAnnotationHover() {
        guard !isInteracting, !isEnteringText,
              let index = hoveredAnnotationIndex,
              index != selectedAnnotationIndex,
              annotations.indices.contains(index) else { return }
        if case let .line(start, end, _, _, _) = annotations[index] {
            for point in [start, end] {
                let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                CaptureAppearance.selectionLightOutline.withAlphaComponent(0.75).setFill()
                dot.fill()
                CaptureAppearance.selectionDarkOutline.withAlphaComponent(0.45).setStroke()
                dot.lineWidth = 0.75
                dot.stroke()
            }
            return
        }
        let rect = annotationCoreBounds(annotations[index]).insetBy(dx: -4, dy: -4)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        CaptureAppearance.selectionLightOutline.withAlphaComponent(0.66).setStroke()
        outline.lineWidth = 2
        outline.stroke()
        CaptureAppearance.selectionDarkOutline.withAlphaComponent(0.36).setStroke()
        outline.lineWidth = 0.75
        outline.stroke()
    }

    private func drawResizeHandle(_ rect: CGRect) {
        // Visual size is deliberately smaller than the hit target.
        let diameter = CaptureAppearance.handleDiameter
        let visual = rect.insetBy(dx: max(0, (rect.width - diameter) / 2), dy: max(0, (rect.height - diameter) / 2))
        NSColor.white.withAlphaComponent(0.98).setFill()
        NSBezierPath(ovalIn: visual).fill()
        CaptureAppearance.selectionDarkOutline.withAlphaComponent(0.65).setStroke()
        let ring = NSBezierPath(ovalIn: visual.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    private func rectangleResizeHandles(at index: Int) -> [(RectangleResizeHandle, CGRect)] {
        guard annotations.indices.contains(index) else { return [] }
        let rect: CGRect
        switch annotations[index] {
        case .rectangle, .ellipse, .mosaic, .pen: rect = annotationGeometryBounds(annotations[index])
        default: return []
        }
        let size: CGFloat = 11
        let centers: [(RectangleResizeHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY))
        ]
        return centers.map { handle, center in
            (
                handle,
                CGRect(
                    x: center.x - size / 2,
                    y: center.y - size / 2,
                    width: size,
                    height: size
                )
            )
        }
    }

    private func lineResizeHandles(at index: Int) -> [(Bool, CGRect)] {
        guard annotations.indices.contains(index),
              case let .line(start, end, _, _, _) = annotations[index] else { return [] }
        return [(true, start), (false, end)].map { isStart, point in
            (isStart, CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11))
        }
    }

    private func rectangleResizeHandle(at point: CGPoint, index: Int) -> RectangleResizeHandle? {
        rectangleResizeHandles(at: index).first { _, rect in
            rect.insetBy(dx: -4, dy: -4).contains(point)
        }?.0
    }

    private func textResizeHandleRect(at index: Int) -> CGRect? {
        guard let rect = textRect(at: index) else { return nil }
        let outline = rect.insetBy(dx: -5, dy: -4)
        let size: CGFloat = 12
        return CGRect(
            x: min(max(bounds.minX, outline.maxX - size / 2), max(bounds.minX, bounds.maxX - size)),
            y: min(max(bounds.minY, outline.maxY - size / 2), max(bounds.minY, bounds.maxY - size)),
            width: size,
            height: size
        )
    }

    private func drawFilledArrow(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
        let path = arrowPath(from: start, to: end, width: width)
        guard !path.isEmpty else { return }
        color.setFill()
        path.fill()
    }

    /// One silhouette owns preview, export, hit testing and invalidation.
    /// A needle tail widens into a slender shaft and sharp triangular head,
    /// matching the reference without stretching a raster arrow image.
    private func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 1, width.isFinite else { return path }

        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        func point(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(
                x: start.x + unit.x * along + normal.x * side,
                y: start.y + unit.y * along + normal.y * side
            )
        }

        let strokeWidth = max(1, width)
        let headLength = min(length * 0.42, max(18, strokeWidth * 5, min(40, length * 0.20)))
        let headHalf = min(length * 0.22, headLength * 0.45)
        let neckHalf = min(headHalf * 0.34, max(1.4, strokeWidth * 0.9))
        let neck = length - headLength * 0.85
        let wing = length - headLength
        path.move(to: start)
        path.curve(
            to: point(neck, neckHalf),
            controlPoint1: point(neck * 0.35, neckHalf * 0.18),
            controlPoint2: point(neck * 0.78, neckHalf * 0.76)
        )
        path.line(to: point(wing, headHalf))
        path.line(to: end)
        path.line(to: point(wing, -headHalf))
        path.line(to: point(neck, -neckHalf))
        path.curve(
            to: start,
            controlPoint1: point(neck * 0.78, -neckHalf * 0.76),
            controlPoint2: point(neck * 0.35, -neckHalf * 0.18)
        )
        path.close()
        return path
    }

    private func drawMosaic(_ rect: CGRect) {
        let scaleX = CGFloat(baseImage.width) / imagePointSize.width
        let scaleY = CGFloat(baseImage.height) / imagePointSize.height
        let crop = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        guard crop.width > 1, crop.height > 1, let piece = baseImage.cropping(to: crop) else { return }
        let tinySize = NSSize(width: max(1, rect.width / 16), height: max(1, rect.height / 16))
        let tiny = NSImage(size: tinySize)
        tiny.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: piece, size: rect.size).draw(in: NSRect(origin: .zero, size: tinySize))
        tiny.unlockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        tiny.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
    }

    func pngData() -> Data? {
        guard let image = flattenedCGImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    func flattenedCGImage() -> CGImage? {
        renderCGImage(alwaysRender: false)
    }

    func longScreenshotSeed(sourceTopLeft: CGPoint) -> CapturedImage? {
        guard isEditing, !isInteracting, !isEnteringText, annotations.isEmpty else { return nil }
        let sx = CGFloat(sourceImage.width) / sourcePointSize.width
        let sy = CGFloat(sourceImage.height) / sourcePointSize.height
        // Initial selection rounds its lower edges down; later edits are
        // already pixel-aligned, with possible floating-point division noise.
        let x = floor(viewport.minX * sx + 0.000001) / sx
        let y = floor(viewport.minY * sy + 0.000001) / sy
        let size = CGSize(width: CGFloat(baseImage.width) / sx, height: CGFloat(baseImage.height) / sy)
        let area = CGRect(x: sourceTopLeft.x + x, y: sourceTopLeft.y - y - size.height,
                          width: size.width, height: size.height)
        return CapturedImage(cgImage: baseImage, pointSize: size, screenRect: area, sourceCGImage: sourceImage)
    }

    /// A pinned image cannot be edited again. Give it an independent bitmap so
    /// a small crop does not keep its full-screen CGImage backing store alive.
    func freezeForPin() -> Bool {
        finishGeometryGesture()
        guard let image = renderCGImage(alwaysRender: true) else { return false }
        sourceImage = image
        baseImage = image
        sourcePointSize = imagePointSize
        viewport = CGRect(origin: .zero, size: imagePointSize)
        displayImage = NSImage(cgImage: image, size: imagePointSize)
        annotations.removeAll()
        textMeasurements.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedAnnotationIndex = nil
        isEditing = false
        needsDisplay = true
        return true
    }

    private func renderCGImage(alwaysRender: Bool) -> CGImage? {
        commitInlineText()
        if annotations.isEmpty, !alwaysRender { return baseImage }

        let width = baseImage.width
        let height = baseImage.height
        guard let rawRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        let colorSpace = baseImage.colorSpace.flatMap { NSColorSpace(cgColorSpace: $0) } ?? .sRGB
        let rep = rawRep.retagging(with: colorSpace) ?? rawRep
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let pixelBounds = CGRect(x: 0, y: 0, width: width, height: height)
        NSImage(cgImage: baseImage, size: pixelBounds.size).draw(
            in: pixelBounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.none]
        )

        context.cgContext.saveGState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(
            x: CGFloat(width) / imagePointSize.width,
            y: -CGFloat(height) / imagePointSize.height
        )
        // The annotation coordinate system is top-left/flipped, just like the
        // editor canvas. Tell AppKit about that orientation so glyphs are not
        // inverted when rendered into the bitmap context.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        annotations.forEach(drawAnnotation)
        context.cgContext.restoreGState()
        NSGraphicsContext.current = context
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

private final class InlineTextSurfaceBackground: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InlineAnnotationTextView: NSTextView {
    private static let fallbackLineLayout = NSLayoutManager()
    private let measuringStorage = NSTextStorage()
    private let measuringLayout = NSLayoutManager()
    private lazy var measuringContainer: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byCharWrapping
        self.measuringLayout.addTextContainer(container)
        self.measuringStorage.addLayoutManager(self.measuringLayout)
        return container
    }()

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLiveTextChange: (() -> Void)?
    private(set) var isHandlingMarkedTextReturn = false
    private(set) var isHandlingModifiedReturn = false
    private var nativeTextMutationDepth = 0
    var isPerformingNativeTextMutation: Bool { nativeTextMutationDepth > 0 }

    static func fallbackLineHeight(for font: NSFont) -> CGFloat {
        max(1, ceil(fallbackLineLayout.defaultLineHeight(for: font)))
    }

    func nativeLineHeight(for font: NSFont) -> CGFloat {
        max(1, ceil((layoutManager ?? Self.fallbackLineLayout).defaultLineHeight(for: font)))
    }

    func measuredNaturalWidth(maximumWidth: CGFloat, fallbackFont: NSFont) -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 8 }
        let container = measuringContainer
        let measurementWidth = max(10_000, maximumWidth * 2)
        if abs(container.containerSize.width - measurementWidth) > 0.25 {
            container.containerSize = NSSize(width: measurementWidth, height: .greatestFiniteMagnitude)
        }

        // Reuse one independent TextKit graph for this editing session. Copy
        // the current native marked attributes without touching live storage
        // or briefly widening the live container beneath the input method.
        measuringStorage.beginEditing()
        measuringStorage.setAttributedString(storage)
        var inheritedFontRanges: [NSRange] = []
        measuringStorage.enumerateAttribute(.font, in: NSRange(location: 0, length: measuringStorage.length), options: []) { font, range, _ in
            if font == nil { inheritedFontRanges.append(range) }
        }
        for range in inheritedFontRanges {
            measuringStorage.addAttribute(.font, value: fallbackFont, range: range)
        }
        measuringStorage.endEditing()
        measuringLayout.ensureLayout(for: container)
        return ceil(measuringLayout.usedRect(for: container).width) + 2
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        nativeTextMutationDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        finishNativeTextMutation()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        nativeTextMutationDepth += 1
        super.insertText(string, replacementRange: replacementRange)
        finishNativeTextMutation()
    }

    override func unmarkText() {
        nativeTextMutationDepth += 1
        super.unmarkText()
        finishNativeTextMutation()
    }

    override func didChangeText() {
        nativeTextMutationDepth += 1
        super.didChangeText()
        finishNativeTextMutation()
    }

    private func finishNativeTextMutation() {
        nativeTextMutationDepth -= 1
        // Native calls can nest (marked text -> insert -> didChangeText).
        // Resize only after the outermost operation has settled its selection
        // and marked range, including input-method changes made by the mouse.
        if nativeTextMutationDepth == 0 { onLiveTextChange?() }
    }

    private func isExplicitLineBreak(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return (event.keyCode == 36 || event.keyCode == 76)
            && flags.contains(.shift) && !flags.contains(.command)
            && !flags.contains(.control) && !flags.contains(.option)
    }

    private func insertExplicitLineBreak() {
        isHandlingModifiedReturn = true
        defer { isHandlingModifiedReturn = false }
        // Do not rely on a user's key-binding dictionary to map Shift-Return.
        // Native insertion preserves the selected range, undo and typography;
        // the existing post-insert callback expands the last empty caret line.
        insertText("\n", replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            // A valid location with length zero is not active composition.
            if hasMarkedText() {
                isHandlingMarkedTextReturn = true
                defer { isHandlingMarkedTextReturn = false }
                super.keyDown(with: event)
                return
            }

            if isExplicitLineBreak(event) {
                insertExplicitLineBreak()
                return
            }

            let hasModifier = flags.contains(.shift)
                || flags.contains(.command)
                || flags.contains(.control)
                || flags.contains(.option)
            if hasModifier {
                isHandlingModifiedReturn = true
                defer { isHandlingModifiedReturn = false }
                super.keyDown(with: event)
                return
            }

            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isExplicitLineBreak(event), !hasMarkedText() {
            insertExplicitLineBreak()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return true
        }
        if flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "z",
           let undoManager {
            if flags.contains(.shift) {
                if undoManager.canRedo { undoManager.redo() }
            } else if undoManager.canUndo {
                undoManager.undo()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class RecognitionResultTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "z":
            if flags.contains(.shift) {
                if undoManager?.canRedo == true { undoManager?.redo() }
            } else if undoManager?.canUndo == true {
                undoManager?.undo()
            }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private final class TextRecognitionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TextRecognitionWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    var onSizeChange: (() -> Void)?
    var onFocusChange: (() -> Void)?

    private let textView = RecognitionResultTextView()
    private let copySelectionButton = NSButton(title: "复制所选", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "识别结果可能有误，可以直接修改。")
    private var keyMonitor: Any?
    private weak var ownerWindow: NSWindow?
    private var preferredSize = CGSize(width: 340, height: 360)
    private var isPositioning = false

    init(text: String) {
        let window = TextRecognitionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "提取文字"
        window.minSize = NSSize(width: 280, height: 236)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = true
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        buildUI(text: text)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        if NSApp.isActive {
            super.showWindow(sender)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(textView)
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 53 || (flags.contains(.command) && ["w", "."].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")) {
                    self.close()
                    return nil
                }
                return event
            }
        }
    }

    func showAnchored(to owner: NSWindow) {
        ownerWindow = owner
        if let window, window.parent == nil { owner.addChildWindow(window, ordered: .above) }
        position(relativeTo: owner.frame, on: owner.screen)
        showWindow(nil)
    }

    func revealWithoutTakingFocus() {
        guard NSApp.isActive, let ownerWindow, ownerWindow.isVisible else { return }
        position(relativeTo: ownerWindow.frame, on: ownerWindow.screen)
        window?.orderFront(nil)
    }

    func position(relativeTo anchor: CGRect, on screen: NSScreen?) {
        guard !isPositioning, let window, let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 12
        let minWidth = min(280, visible.width)
        let minHeight = min(236, visible.height)
        var size = CGSize(width: min(max(minWidth, preferredSize.width), visible.width), height: min(max(minHeight, preferredSize.height), visible.height))
        let rightSpace = visible.maxX - anchor.maxX - gap
        let leftSpace = anchor.minX - visible.minX - gap
        let belowSpace = anchor.minY - visible.minY - gap
        let aboveSpace = visible.maxY - anchor.maxY - gap
        var origin: CGPoint
        if rightSpace >= minWidth {
            size.width = min(size.width, rightSpace)
            origin = CGPoint(x: anchor.maxX + gap, y: anchor.maxY - size.height)
        } else if leftSpace >= minWidth {
            size.width = min(size.width, leftSpace)
            origin = CGPoint(x: anchor.minX - gap - size.width, y: anchor.maxY - size.height)
        } else if belowSpace >= minHeight || aboveSpace >= minHeight {
            let useBelow = belowSpace >= minHeight
            size.height = min(size.height, useBelow ? belowSpace : aboveSpace)
            origin = CGPoint(x: anchor.midX - size.width / 2, y: useBelow ? anchor.minY - gap - size.height : anchor.maxY + gap)
        } else {
            // A full-screen capture has no adjacent free edge. Keep the card
            // compact in a corner without moving or resizing the screenshot.
            size.height = min(size.height, max(minHeight, visible.height * 0.5))
            origin = CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        let frame = CGRect(origin: origin, size: size)
        isPositioning = true
        if window.frame != frame { window.setFrame(frame, display: true, animate: false) }
        window.level = ownerWindow?.level ?? .floating
        isPositioning = false
    }

    private func buildUI(text: String) {
        guard let window else { return }
        let contentView = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = CaptureAppearance.surfaceBackground(
            frame: contentView.bounds,
            host: contentView,
            cornerRadius: CaptureAppearance.panelCornerRadius
        )

        let heading = NSTextField(labelWithString: "文字识别")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let retryButton = headerButton(symbol: "arrow.clockwise", tip: "重新识别", action: #selector(retryRecognition))
        let closeButton = headerButton(symbol: "xmark", tip: "关闭识别结果（Esc / ⌘W）", action: #selector(closeResult))
        let header = NSStackView(views: [icon, heading, NSView(), retryButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        textView.string = text
        let bodyFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        textView.font = bodyFont
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (text as NSString).length))
        textView.typingAttributes = [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.toolTip = "可直接修改文字；选择后按 ⌘C 复制"
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.borderWidth = 0
        textView.frame = scrollView.contentView.bounds
        scrollView.documentView = textView

        copySelectionButton.target = self
        copySelectionButton.action = #selector(copySelection)
        copySelectionButton.bezelStyle = .rounded
        copySelectionButton.controlSize = .small
        copySelectionButton.isEnabled = false

        let copyAllButton = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copyAllButton.bezelStyle = .rounded
        copyAllButton.controlSize = .small

        let spacer = NSView()
        let buttonRow = NSStackView(views: [copySelectionButton, copyAllButton, spacer])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "\(text.count) 个字符 · 可编辑"
        statusLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [header, scrollView, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func headerButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.toolTip = tip
        CaptureAppearance.styleButton(button)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        copySelectionButton.isEnabled = textView.selectedRange().length > 0
    }

    func textDidChange(_ notification: Notification) {
        statusLabel.stringValue = "已修改识别结果"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func copySelection() {
        let range = textView.selectedRange()
        guard range.length > 0,
              let swiftRange = Range(range, in: textView.string) else { return }
        copyToPasteboard(String(textView.string[swiftRange]))
    }

    @objc private func copyAll() {
        copyToPasteboard(textView.string)
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else {
            statusLabel.stringValue = "没有可复制的文字"
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) {
            statusLabel.stringValue = "已复制 \(text.count) 个字符"
            statusLabel.textColor = .systemGreen
            CopyConfirmationPresenter.shared.show(on: window?.screen)
        } else {
            statusLabel.stringValue = "复制失败，请重试"
            statusLabel.textColor = .systemRed
            CopyConfirmationPresenter.shared.show(
                title: "复制失败", message: "请重试。", symbol: "exclamationmark.circle",
                on: window?.screen, duration: 4.5
            )
        }
    }

    @objc private func closeResult() { close() }
    @objc private func retryRecognition() { onRetry?() }

    func windowDidResize(_ notification: Notification) {
        guard !isPositioning, let window else { return }
        preferredSize = window.frame.size
        onSizeChange?()
    }

    func windowDidBecomeKey(_ notification: Notification) { onFocusChange?() }
    func windowDidResignKey(_ notification: Notification) { onFocusChange?() }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let window { ownerWindow?.removeChildWindow(window) }
        ownerWindow = nil
        onRetry = nil
        onSizeChange = nil
        onFocusChange = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
