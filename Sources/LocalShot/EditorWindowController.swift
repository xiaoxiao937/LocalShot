import AppKit
import UniformTypeIdentifiers
import Vision

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

enum Annotation {
    case line(CGPoint, CGPoint, NSColor, CGFloat, Bool)
    case rectangle(CGRect, NSColor, CGFloat)
    case ellipse(CGRect, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)
    case mosaic(CGRect)
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let settings: SettingsStore
    private let canvas: EditorCanvasView
    private let toolbarPanel: NSPanel
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 20, target: nil, action: nil)
    private var toolButtons: [NSButton] = []
    private var closeKeyMonitor: Any?
    private var textResultController: TextRecognitionWindowController?
    private lazy var pinCloseButton: NSButton = {
        let image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "关闭贴图"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(closeEditor))
        button.bezelStyle = .circular
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = "关闭贴图（Esc 或 ⌘W）"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    init(image: CapturedImage, settings: SettingsStore) {
        self.settings = settings
        canvas = EditorCanvasView(image: image)
        let window = EditorOverlayWindow(
            contentRect: NSRect(origin: image.screenRect?.origin ?? .zero, size: image.pointSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        toolbarPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 52),
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
        canvas.onToolChangeRequest = { [weak self] tool in self?.setTool(tool) }
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        installCloseKeyMonitor()
        positionToolbar()
        toolbarPanel.orderFront(nil)
        if toolbarPanel.parent == nil {
            window?.addChildWindow(toolbarPanel, ordered: .above)
        }
        window?.makeFirstResponder(canvas)
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

        let styleGroup = toolbarGroup(spacing: 6)
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "标注颜色"
        colorWell.colorWellStyle = .minimal
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        styleGroup.addArrangedSubview(colorWell)

        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.toolTip = "线条粗细"
        styleGroup.addArrangedSubview(widthSlider)

        let editActionGroup = toolbarGroup()
        editActionGroup.addArrangedSubview(iconButton(symbol: "arrow.uturn.backward", tip: "撤销", action: #selector(undo)))
        editActionGroup.addArrangedSubview(iconButton(symbol: "arrow.uturn.forward", tip: "重做", action: #selector(redo)))
        editActionGroup.addArrangedSubview(iconButton(symbol: "text.viewfinder", tip: "提取文字", action: #selector(recognizeText)))
        editActionGroup.addArrangedSubview(iconButton(symbol: "pin", tip: "贴图", action: #selector(pinImage)))

        let completionGroup = toolbarGroup()
        completionGroup.addArrangedSubview(iconButton(symbol: "square.and.arrow.down", tip: "下载 PNG", action: #selector(saveImage)))
        let finish = iconButton(symbol: "checkmark", tip: "复制并完成", action: #selector(finishEditing))
        finish.contentTintColor = .systemGreen
        completionGroup.addArrangedSubview(finish)
        let cancel = iconButton(symbol: "xmark", tip: "取消", action: #selector(closeEditor))
        cancel.contentTintColor = .systemRed
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
        toolbar.spacing = 8

        toolbar.layoutSubtreeIfNeeded()
        let fitting = toolbar.fittingSize
        let contentSize = CGSize(width: ceil(fitting.width) + 20, height: 52)
        toolbarPanel.setContentSize(contentSize)

        let host = NSView(frame: NSRect(origin: .zero, size: contentSize))
        host.autoresizingMask = [.width, .height]
        toolbar.frame = NSRect(
            x: 10,
            y: floor((contentSize.height - fitting.height) / 2),
            width: fitting.width,
            height: fitting.height
        )
        toolbar.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        host.addSubview(toolbar)
        toolbarPanel.contentView = toolbarBackground(frame: NSRect(origin: .zero, size: contentSize), host: host)
        styleChanged()
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
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return separator
    }

    private func toolbarBackground(frame: NSRect, host: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = 16
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08)
            glass.style = .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            glass.contentView = host
            return glass
        }

        let effect = NSVisualEffectView(frame: frame)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.addSubview(host)
        return effect
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
        canvas.tool = tool
        toolButtons.forEach { $0.state = ($0.tag == tool.rawValue) ? .on : .off }
    }

    @objc private func styleChanged() {
        canvas.strokeColor = colorWell.color
        canvas.strokeWidth = widthSlider.doubleValue
    }

    @objc private func undo() { canvas.undoLast() }
    @objc private func redo() { canvas.redoLast() }

    @objc private func recognizeText() {
        guard let image = canvas.flattenedCGImage() else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            guard !text.isEmpty else {
                showFeedback(title: "没有识别到文字", message: "请换一个包含清晰文字的区域再试。")
                return
            }
            let controller = TextRecognitionWindowController(text: text)
            controller.onClose = { [weak self, weak controller] in
                guard let self, self.textResultController === controller else { return }
                self.textResultController = nil
            }
            textResultController?.close()
            textResultController = controller
            controller.showWindow(nil)
        } catch {
            showFeedback(title: "文字识别失败", message: error.localizedDescription)
        }
    }

    @objc private func pinImage() {
        canvas.isEditing = false
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
    }

    @objc private func copyImage() {
        guard let data = canvas.pngData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    @objc private func saveImage() {
        guard let data = canvas.pngData() else { return }
        var destination: URL?
        var scopedFolder: URL?
        var isAccessingScope = false
        if settings.askSaveLocation || settings.saveDirectoryURL == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = settings.suggestedFileName()
            panel.canCreateDirectories = true
            if panel.runModal() == .OK { destination = panel.url }
        } else if let folder = settings.saveDirectoryURL {
            isAccessingScope = folder.startAccessingSecurityScopedResource()
            scopedFolder = folder
            destination = uniqueURL(in: folder, named: settings.suggestedFileName())
        }
        guard let destination else { return }
        defer {
            if isAccessingScope { scopedFolder?.stopAccessingSecurityScopedResource() }
        }
        do {
            try data.write(to: destination, options: .atomic)
            settings.recordSavedURL(destination)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "保存失败"
            alert.runModal()
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

    private func showFeedback(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func closeEditor() { close() }

    @objc private func finishEditing() {
        copyImage()
        close()
    }

    private func installCloseKeyMonitor() {
        guard closeKeyMonitor == nil else { return }
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandW = flags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "w"
            if isCommandW {
                self.close()
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
        let editorFrame = window.frame
        let visible = screen.visibleFrame
        var toolbarFrame = toolbarPanel.frame
        let horizontalInset: CGFloat = 8
        let centeredX = editorFrame.midX - toolbarFrame.width / 2
        let minimumX = visible.minX + horizontalInset
        let maximumX = visible.maxX - toolbarFrame.width - horizontalInset
        toolbarFrame.origin.x = maximumX >= minimumX
            ? min(max(centeredX, minimumX), maximumX)
            : visible.midX - toolbarFrame.width / 2
        if editorFrame.minY - toolbarFrame.height - 8 >= visible.minY {
            toolbarFrame.origin.y = editorFrame.minY - toolbarFrame.height - 8
        } else if editorFrame.maxY + toolbarFrame.height + 8 <= visible.maxY {
            toolbarFrame.origin.y = editorFrame.maxY + 8
        } else {
            toolbarFrame.origin.y = visible.minY + 8
        }
        toolbarPanel.setFrame(toolbarFrame, display: true)
    }

    private func resizeCanvas(to size: CGSize) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        positionToolbar()
    }

    func windowWillClose(_ notification: Notification) {
        if let closeKeyMonitor {
            NSEvent.removeMonitor(closeKeyMonitor)
            self.closeKeyMonitor = nil
        }
        toolbarPanel.orderOut(nil)
        textResultController?.close()
        textResultController = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

final class EditorOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class EditorCanvasView: NSView, NSTextFieldDelegate {
    var onSizeChange: ((CGSize) -> Void)?
    var onToolChangeRequest: ((EditorTool) -> Void)?
    var isEditing = true {
        didSet {
            if !isEditing { commitInlineText() }
        }
    }
    var tool: EditorTool = .move {
        didSet {
            if oldValue == .text, tool != .text { commitInlineText() }
            window?.invalidateCursorRects(for: self)
        }
    }
    var strokeColor: NSColor = .systemRed {
        didSet {
            inlineTextField?.textColor = strokeColor
            inlineTextField?.layer?.borderColor = strokeColor.cgColor
        }
    }
    var strokeWidth: CGFloat = 4

    private var baseImage: CGImage
    private var imagePointSize: CGSize
    private var displayImage: NSImage
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var penPoints: [CGPoint] = []
    private var inlineTextField: InlineAnnotationTextField?
    private var inlineTextContainer: NSView?
    private var inlineTextPoint: CGPoint?
    private var selectedTextIndex: Int?
    private var movingTextStart: CGPoint?
    private var movingTextOriginalPoint: CGPoint?
    private var resizingTextIndex: Int?
    private var resizingTextOriginalSize: CGFloat?
    private var resizingTextOriginalDistance: CGFloat?

    var isEnteringText: Bool { inlineTextField != nil }

    init(image: CapturedImage) {
        baseImage = image.cgImage
        imagePointSize = image.pointSize
        displayImage = NSImage(cgImage: image.cgImage, size: image.pointSize)
        super.init(frame: NSRect(origin: .zero, size: image.pointSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        displayImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        annotations.forEach(drawAnnotation)
        drawTextSelection()
        drawDraft()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: tool == .move ? .openHand : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        if inlineTextField != nil { commitInlineText(activateMoveTool: true) }
        guard isEditing else {
            window?.performDrag(with: event)
            return
        }
        let point = bounded(convert(event.locationInWindow, from: nil))
        if tool == .move {
            if let selectedTextIndex,
               annotations.indices.contains(selectedTextIndex),
               textResizeHandleRect(at: selectedTextIndex)?.contains(point) == true,
               case let .text(_, origin, _, fontSize) = annotations[selectedTextIndex] {
                resizingTextIndex = selectedTextIndex
                resizingTextOriginalSize = fontSize
                resizingTextOriginalDistance = max(1, hypot(point.x - origin.x, point.y - origin.y))
                movingTextStart = nil
                movingTextOriginalPoint = nil
                return
            }
            if let index = textAnnotationIndex(at: point),
               case let .text(_, originalPoint, _, _) = annotations[index] {
                selectedTextIndex = index
                movingTextStart = point
                movingTextOriginalPoint = originalPoint
                needsDisplay = true
            } else {
                selectedTextIndex = nil
                movingTextStart = nil
                movingTextOriginalPoint = nil
                needsDisplay = true
                window?.performDrag(with: event)
            }
            return
        }
        selectedTextIndex = nil
        dragStart = point
        dragCurrent = point
        penPoints = [point]
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.windowController?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing else { return }
        let point = bounded(convert(event.locationInWindow, from: nil))
        if tool == .move,
           let index = resizingTextIndex,
           annotations.indices.contains(index),
           let originalSize = resizingTextOriginalSize,
           let originalDistance = resizingTextOriginalDistance,
           case let .text(text, origin, color, _) = annotations[index] {
            let currentDistance = max(1, hypot(point.x - origin.x, point.y - origin.y))
            let fontSize = min(120, max(10, originalSize * currentDistance / originalDistance))
            annotations[index] = .text(text, origin, color, fontSize)
            needsDisplay = true
            return
        }
        if tool == .move,
           let index = selectedTextIndex,
           annotations.indices.contains(index),
           let movingTextStart,
           let movingTextOriginalPoint,
           case let .text(text, _, color, fontSize) = annotations[index] {
            let size = textSize(text, color: color, fontSize: fontSize)
            let proposed = CGPoint(
                x: movingTextOriginalPoint.x + point.x - movingTextStart.x,
                y: movingTextOriginalPoint.y + point.y - movingTextStart.y
            )
            let destination = CGPoint(
                x: min(max(0, proposed.x), max(0, bounds.width - size.width)),
                y: min(max(0, proposed.y), max(0, bounds.height - size.height))
            )
            annotations[index] = .text(text, destination, color, fontSize)
            needsDisplay = true
            return
        }
        dragCurrent = point
        if tool == .pen { penPoints.append(point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditing else { return }
        if tool == .move, resizingTextIndex != nil {
            resizingTextIndex = nil
            resizingTextOriginalSize = nil
            resizingTextOriginalDistance = nil
            needsDisplay = true
            return
        }
        if tool == .move, movingTextStart != nil {
            movingTextStart = nil
            movingTextOriginalPoint = nil
            needsDisplay = true
            return
        }
        dragCurrent = bounded(convert(event.locationInWindow, from: nil))
        guard let start = dragStart, let end = dragCurrent else { return resetDraft() }
        let rect = normalizedRect(start, end)

        switch tool {
        case .move: break
        case .line: add(.line(start, end, strokeColor, strokeWidth, false))
        case .arrow: add(.line(start, end, strokeColor, strokeWidth, true))
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
        commitInlineText()

        let horizontalInset: CGFloat = 8
        let fieldHeight: CGFloat = 42
        let fieldWidth = max(120, min(240, bounds.width - horizontalInset * 2))
        let origin = CGPoint(
            x: min(max(horizontalInset, point.x), max(horizontalInset, bounds.width - fieldWidth - horizontalInset)),
            y: min(max(0, point.y), max(0, bounds.height - fieldHeight))
        )
        let containerFrame = NSRect(origin: origin, size: CGSize(width: fieldWidth, height: fieldHeight))
        let (container, host) = makeInlineTextContainer(frame: containerFrame)
        let field = InlineAnnotationTextField(frame: NSRect(x: 10, y: 5, width: fieldWidth - 20, height: fieldHeight - 10))
        field.autoresizingMask = [.width, .height]
        field.font = .systemFont(ofSize: 22, weight: .medium)
        field.textColor = strokeColor
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.cell?.lineBreakMode = .byClipping
        field.placeholderAttributedString = NSAttributedString(
            string: "输入文字",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        field.delegate = self
        field.target = self
        field.action = #selector(commitInlineTextFromField(_:))
        field.onCancel = { [weak self] in self?.cancelInlineText() }

        inlineTextField = field
        inlineTextContainer = container
        inlineTextPoint = origin
        host.addSubview(field)
        addSubview(container)
        window?.makeFirstResponder(field)
    }

    private func makeInlineTextContainer(frame: NSRect) -> (NSView, NSView) {
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = frame.height / 2
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.06)
            glass.style = .regular
            glass.contentView = host
            return (glass, host)
        }

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = frame.height / 2
        effect.layer?.masksToBounds = true
        effect.addSubview(host)
        return (effect, host)
    }

    @objc private func commitInlineTextFromField(_ sender: Any?) {
        commitInlineText(activateMoveTool: true)
    }

    private func commitInlineText(activateMoveTool: Bool = false) {
        finishInlineText(shouldCommit: true, activateMoveTool: activateMoveTool)
    }

    private func cancelInlineText() {
        finishInlineText(shouldCommit: false, activateMoveTool: false)
    }

    private func finishInlineText(shouldCommit: Bool, activateMoveTool: Bool) {
        guard let field = inlineTextField else { return }

        field.delegate = nil
        field.target = nil
        field.onCancel = nil
        field.validateEditing()
        let text = field.stringValue
        let point = inlineTextPoint ?? field.frame.origin
        inlineTextField = nil
        let container = inlineTextContainer
        inlineTextContainer = nil
        inlineTextPoint = nil

        if let editor = field.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(self)
        }
        field.removeFromSuperview()
        container?.removeFromSuperview()

        if shouldCommit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let index = add(.text(text, point, field.textColor ?? strokeColor, 28))
            selectedTextIndex = index
            if activateMoveTool {
                onToolChangeRequest?(.move)
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard inlineTextField != nil else { return }
        let movement = (obj.userInfo?[NSText.movementUserInfoKey] as? NSNumber)?.intValue
        if movement == NSTextMovement.cancel.rawValue {
            cancelInlineText()
        } else {
            commitInlineText(activateMoveTool: true)
        }
    }

    @discardableResult
    private func add(_ annotation: Annotation) -> Int {
        annotations.append(annotation)
        selectedTextIndex = nil
        redoStack.removeAll()
        needsDisplay = true
        return annotations.count - 1
    }

    func undoLast() {
        commitInlineText()
        selectedTextIndex = nil
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
    }

    func redoLast() {
        commitInlineText()
        selectedTextIndex = nil
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
        needsDisplay = true
    }

    private func applyCrop(_ rect: CGRect) {
        let scaleX = CGFloat(baseImage.width) / imagePointSize.width
        let scaleY = CGFloat(baseImage.height) / imagePointSize.height
        let imageBounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let crop = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral.intersection(imageBounds)
        guard let cropped = baseImage.cropping(to: crop) else { return }
        imagePointSize = CGSize(width: crop.width / scaleX, height: crop.height / scaleY)
        baseImage = cropped
        displayImage = NSImage(cgImage: cropped, size: imagePointSize)
        annotations.removeAll()
        selectedTextIndex = nil
        redoStack.removeAll()
        frame.size = imagePointSize
        onSizeChange?(imagePointSize)
        needsDisplay = true
    }

    private func resetDraft() {
        dragStart = nil
        dragCurrent = nil
        penPoints.removeAll()
        needsDisplay = true
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
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
            case .rectangle, .crop: drawAnnotation(.rectangle(rect, strokeColor, strokeWidth))
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
        case let .text(text, point, color, fontSize):
            text.draw(at: point, withAttributes: textAttributes(color: color, fontSize: fontSize))
        case let .mosaic(rect):
            drawMosaic(rect)
        }
    }

    private func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .strokeColor: NSColor.white.withAlphaComponent(0.35),
            .strokeWidth: -1
        ]
    }

    private func textSize(_ text: String, color: NSColor, fontSize: CGFloat) -> CGSize {
        let measured = text.size(withAttributes: textAttributes(color: color, fontSize: fontSize))
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    private func textRect(text: String, point: CGPoint, color: NSColor, fontSize: CGFloat) -> CGRect {
        CGRect(origin: point, size: textSize(text, color: color, fontSize: fontSize))
    }

    private func textRect(at index: Int) -> CGRect? {
        guard annotations.indices.contains(index),
              case let .text(text, point, color, fontSize) = annotations[index] else { return nil }
        return textRect(text: text, point: point, color: color, fontSize: fontSize)
    }

    private func textAnnotationIndex(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first { index in
            textRect(at: index)?.insetBy(dx: -6, dy: -5).contains(point) == true
        }
    }

    private func drawTextSelection() {
        guard tool == .move,
              let selectedTextIndex,
              let rect = textRect(at: selectedTextIndex) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -5, dy: -4), xRadius: 5, yRadius: 5)
        outline.lineWidth = 1.5
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.stroke()

        if let handle = textResizeHandleRect(at: selectedTextIndex) {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: handle).fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let ring = NSBezierPath(ovalIn: handle.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private func textResizeHandleRect(at index: Int) -> CGRect? {
        guard let rect = textRect(at: index) else { return nil }
        let outline = rect.insetBy(dx: -5, dy: -4)
        let size: CGFloat = 12
        return CGRect(
            x: outline.maxX - size / 2,
            y: outline.maxY - size / 2,
            width: size,
            height: size
        )
    }

    private func drawFilledArrow(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else {
            color.setFill()
            let radius = max(2, width * 0.65)
            NSBezierPath(ovalIn: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)).fill()
            return
        }

        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        func point(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(
                x: start.x + unit.x * along + normal.x * side,
                y: start.y + unit.y * along + normal.y * side
            )
        }

        let shaftHalf = min(length * 0.12, max(2, width * 0.68))
        let headLength = min(length * 0.48, max(18, width * 4.2))
        let headHalf = min(
            max(shaftHalf * 1.75, headLength * 0.58),
            max(9, width * 2.15)
        )
        let shoulder = max(shaftHalf, length - headLength)
        let shoulderRadius = min(
            max(1, width * 0.45),
            max(1, (headHalf - shaftHalf) * 0.35),
            headLength * 0.10
        )
        let diagonalSlope = headHalf / max(headLength, 1)
        let tipInset = min(max(0.8, width * 0.22), headLength * 0.08)
        let upperDiagonalStart = point(shoulder + shoulderRadius, headHalf - shoulderRadius * diagonalSlope)
        let lowerDiagonalStart = point(shoulder + shoulderRadius, -headHalf + shoulderRadius * diagonalSlope)
        let upperTip = point(length - tipInset, tipInset * diagonalSlope)
        let lowerTip = point(length - tipInset, -tipInset * diagonalSlope)

        let path = NSBezierPath()
        path.move(to: point(0, shaftHalf))
        path.line(to: point(shoulder - shoulderRadius, shaftHalf))
        path.curve(
            to: point(shoulder, shaftHalf + shoulderRadius),
            controlPoint1: point(shoulder, shaftHalf),
            controlPoint2: point(shoulder, shaftHalf)
        )
        path.line(to: point(shoulder, headHalf - shoulderRadius))
        path.curve(
            to: upperDiagonalStart,
            controlPoint1: point(shoulder, headHalf),
            controlPoint2: point(shoulder, headHalf)
        )
        path.line(to: upperTip)
        path.curve(to: lowerTip, controlPoint1: end, controlPoint2: end)
        path.line(to: lowerDiagonalStart)
        path.curve(
            to: point(shoulder, -headHalf + shoulderRadius),
            controlPoint1: point(shoulder, -headHalf),
            controlPoint2: point(shoulder, -headHalf)
        )
        path.line(to: point(shoulder, -shaftHalf - shoulderRadius))
        path.curve(
            to: point(shoulder - shoulderRadius, -shaftHalf),
            controlPoint1: point(shoulder, -shaftHalf),
            controlPoint2: point(shoulder, -shaftHalf)
        )
        path.line(to: point(0, -shaftHalf))
        path.curve(
            to: point(-shaftHalf, 0),
            controlPoint1: point(-shaftHalf * 0.55, -shaftHalf),
            controlPoint2: point(-shaftHalf, -shaftHalf * 0.55)
        )
        path.curve(
            to: point(0, shaftHalf),
            controlPoint1: point(-shaftHalf, shaftHalf * 0.55),
            controlPoint2: point(-shaftHalf * 0.55, shaftHalf)
        )
        path.close()
        color.setFill()
        path.fill()
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
        commitInlineText()
        if annotations.isEmpty {
            return NSBitmapImageRep(cgImage: baseImage).representation(using: .png, properties: [:])
        }

        let width = baseImage.width
        let height = baseImage.height
        guard let rep = NSBitmapImageRep(
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
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

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
        return rep.representation(using: .png, properties: [:])
    }

    func flattenedCGImage() -> CGImage? {
        guard let data = pngData() else { return nil }
        return NSBitmapImageRep(data: data)?.cgImage
    }
}

private final class InlineAnnotationTextField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
private final class TextRecognitionWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClose: (() -> Void)?

    private let textView = NSTextView()
    private let copySelectionButton = NSButton(title: "复制所选", target: nil, action: nil)

    init(text: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "提取文字"
        window.minSize = NSSize(width: 380, height: 260)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI(text: text)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
    }

    private func buildUI(text: String) {
        guard let contentView = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "识别结果")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let guidance = NSTextField(labelWithString: "拖动选择需要的文字，再点“复制所选”；也可以复制全部。")
        guidance.font = .systemFont(ofSize: 12)
        guidance.textColor = .secondaryLabelColor

        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
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
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        textView.frame = scrollView.contentView.bounds
        scrollView.documentView = textView

        copySelectionButton.target = self
        copySelectionButton.action = #selector(copySelection)
        copySelectionButton.bezelStyle = .rounded
        copySelectionButton.isEnabled = false

        let copyAllButton = NSButton(title: "复制全部", target: self, action: #selector(copyAll))
        copyAllButton.bezelStyle = .rounded

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeResult))
        closeButton.bezelStyle = .rounded

        let spacer = NSView()
        let buttonRow = NSStackView(views: [copySelectionButton, copyAllButton, spacer, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [heading, guidance, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        copySelectionButton.isEnabled = textView.selectedRange().length > 0
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func closeResult() { close() }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
    }
}
