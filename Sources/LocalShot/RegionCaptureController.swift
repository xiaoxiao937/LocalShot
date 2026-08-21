import AppKit

final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class RegionCaptureController {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let window: CaptureOverlayWindow
    private let selectionView: RegionSelectionView
    private var escapeMonitor: Any?
    private var didFinish = false
    private var cursorIsPushed = false

    init(screen: NSScreen, windowCandidates: [CGRect]) {
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
        selectionView = RegionSelectionView(windowCandidates: windowCandidates, safeInsets: safeInsets)
        window.contentView = selectionView
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A nearly transparent backing keeps the complete overlay inside the
        // WindowServer hit-test region, including the visually clear cutout.
        window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        window.isOpaque = false
        window.hasShadow = false
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false

        selectionView.onComplete = { [weak self] selection in
            guard let self else { return }
            let completion = self.onComplete
            self.finish()
            completion?(selection)
        }
        selectionView.onCancel = { [weak self] in
            self?.cancelCapture()
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        installEscapeMonitor()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(selectionView)
        NSCursor.crosshair.push()
        cursorIsPushed = true

        // A modal event loop guarantees that mouse and keyboard events stay in
        // the capture overlay instead of reaching applications underneath it.
        NSApp.runModal(for: window)
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if NSApp.modalWindow === window {
            NSApp.stopModal()
        }
        if cursorIsPushed {
            NSCursor.pop()
            cursorIsPushed = false
        }
        window.orderOut(nil)
    }

    private func cancelCapture() {
        guard !didFinish else { return }
        let cancellation = onCancel
        finish()
        cancellation?()
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelCapture()
            return nil
        }
    }
}

final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let windowCandidates: [CGRect]
    private let safeInsets: NSEdgeInsets
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var hoveredWindow: CGRect?
    private var snappedWindow: CGRect?
    private var isFreeformDrag = false
    private var didComplete = false
    private var trackingArea: NSTrackingArea?

    init(windowCandidates: [CGRect], safeInsets: NSEdgeInsets = .init()) {
        self.windowCandidates = windowCandidates
        self.safeInsets = safeInsets
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let selection = displayedSelectionRect, selection.width > 1, selection.height > 1 else {
            NSColor.black.withAlphaComponent(0.34).setFill()
            bounds.fill()
            drawHint()
            return
        }

        // The hole remains fully transparent, so users see the live desktop at
        // native display quality instead of a captured image being re-rendered.
        NSColor.black.withAlphaComponent(0.34).setFill()
        let dimmingPath = NSBezierPath(rect: bounds)
        dimmingPath.appendRect(selection)
        dimmingPath.windingRule = .evenOdd
        dimmingPath.fill()

        (isShowingWindowCandidate ? NSColor.systemGreen : NSColor.white).setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = isShowingWindowCandidate ? 2 : 1.5
        border.stroke()

        drawSizeLabel(for: selection)

        if startPoint == nil {
            drawHint()
        }
    }

    private func drawHint() {
        let text = windowCandidates.isEmpty
            ? "拖动框选区域    Esc 退出"
            : "单击选择窗口    拖动框选区域    Esc 退出"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .kern: 0.15
        ]
        let size = text.size(withAttributes: attributes)
        let pillSize = CGSize(width: ceil(size.width) + 32, height: ceil(size.height) + 18)
        let minimumX = bounds.minX + safeInsets.left + 10
        let maximumX = bounds.maxX - safeInsets.right - pillSize.width - 10
        let centeredX = floor(bounds.midX - pillSize.width / 2)
        let pillRect = CGRect(
            x: maximumX >= minimumX ? min(max(centeredX, minimumX), maximumX) : centeredX,
            y: bounds.minY + safeInsets.top + 12,
            width: pillSize.width,
            height: pillSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: 3)
        shadow.set()
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let outline = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
        outline.lineWidth = 1
        outline.stroke()

        text.draw(
            at: CGPoint(x: pillRect.minX + 16, y: pillRect.minY + 9),
            withAttributes: attributes
        )
    }

    private func drawSizeLabel(for selection: CGRect) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94)
        ]
        let size = text.size(withAttributes: attributes)
        let labelSize = CGSize(width: ceil(size.width) + 14, height: ceil(size.height) + 8)
        let safeTop = bounds.minY + safeInsets.top + 6
        let safeLeft = bounds.minX + safeInsets.left + 6
        let safeRight = bounds.maxX - safeInsets.right - 6
        var origin = CGPoint(x: selection.minX, y: selection.minY - labelSize.height - 6)
        if origin.y < safeTop { origin.y = selection.minY + 6 }
        origin.x = min(max(safeLeft, origin.x), max(safeLeft, safeRight - labelSize.width))
        let labelRect = CGRect(origin: origin, size: labelSize)

        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(x: labelRect.minX + 7, y: labelRect.minY + 4),
            withAttributes: attributes
        )
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
        if isFreeformDrag { return freeformSelectionRect }
        return snappedWindow ?? hoveredWindow
    }

    private var isShowingWindowCandidate: Bool {
        !isFreeformDrag && displayedSelectionRect != nil
    }

    private func windowCandidate(at point: CGPoint) -> CGRect? {
        windowCandidates
            .filter { $0.contains(point) }
            .min { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height }
    }

    private func pointInBounds(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard startPoint == nil, !didComplete else { return }
        hoveredWindow = windowCandidate(at: pointInBounds(from: event))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !didComplete else { return }
        startPoint = pointInBounds(from: event)
        currentPoint = startPoint
        snappedWindow = hoveredWindow ?? startPoint.flatMap { windowCandidate(at: $0) }
        isFreeformDrag = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = pointInBounds(from: event)
        if let startPoint, let currentPoint,
           hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) >= 6 {
            isFreeformDrag = true
            snappedWindow = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !didComplete else { return }
        currentPoint = pointInBounds(from: event)

        if isFreeformDrag {
            if let rect = freeformSelectionRect, rect.width >= 4, rect.height >= 4 {
                complete(with: rect)
            } else {
                resetInteraction()
            }
            return
        }

        if let rect = snappedWindow ?? hoveredWindow ?? windowCandidate(at: currentPoint ?? .zero) {
            complete(with: rect)
            return
        }

        resetInteraction()
    }

    private func complete(with rect: CGRect) {
        let selection = rect.integral.intersection(bounds)
        guard selection.width >= 1, selection.height >= 1 else {
            resetInteraction()
            return
        }
        didComplete = true
        onComplete?(selection)
    }

    private func resetInteraction() {
        startPoint = nil
        currentPoint = nil
        snappedWindow = nil
        isFreeformDrag = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}
