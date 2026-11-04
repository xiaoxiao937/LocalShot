import AppKit
import UniformTypeIdentifiers

enum LongScreenshotError: LocalizedError {
    case tooSmall, limit, changedSize, unchanged, noOverlap, ambiguous, bitmap, captureTimedOut

    var errorDescription: String? {
        switch self {
        case .tooSmall: return "范围太小，请重新圈一个较高、较宽的内容区。"
        case .limit: return "已达到长图大小上限。请先复制或保存，再开始下一张。"
        case .changedSize: return "画面尺寸变了，请重新开始长截图。"
        case .unchanged: return "画面没有变化。往下滚一小段，再点「接一屏」。"
        case .noOverlap: return "没找到重叠。回滚一点，和上一屏留出至少四分之一的相同内容。"
        case .ambiguous: return "接缝不够明确。试着多留一些有文字的重叠区域，避开固定栏和重复图案。"
        case .bitmap: return "无法处理这张图，已保留之前拼好的部分。"
        case .captureTimedOut: return "这一屏取图超时，请再试一次。"
        }
    }
}

/// One compact last frame plus non-overlapping output strips. No file cache.
struct LongScreenshotStitcher {
    private static let maximumPixels = 24_000_000
    private static let maximumHeight = 30_000
    private static let maximumFrames = 32
    let width: Int
    let frameHeight: Int
    private let colorSpace: CGColorSpace
    private var strips: [CGImage]
    private var last: CGImage
    private(set) var height: Int
    var frameCount: Int { strips.count }

    init(first: CGImage) throws {
        guard first.width >= 64, first.height >= 96 else { throw LongScreenshotError.tooSmall }
        guard first.height <= Self.maximumHeight,
              first.width <= Self.maximumPixels / first.height else { throw LongScreenshotError.limit }
        width = first.width
        frameHeight = first.height
        height = first.height
        let outputSpace = first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        colorSpace = outputSpace
        let compact = try Self.copy(first, in: outputSpace)
        last = compact
        strips = [compact]
    }

    mutating func append(_ image: CGImage) throws {
        guard image.width == width, image.height == frameHeight else { throw LongScreenshotError.changedSize }
        guard frameCount < Self.maximumFrames else { throw LongScreenshotError.limit }
        let displacement = try Self.displacement(previous: last, next: image)
        let nextHeight = height + displacement
        guard nextHeight <= Self.maximumHeight, width <= Self.maximumPixels / nextHeight else {
            throw LongScreenshotError.limit
        }
        try Task.checkCancellation()
        let compact = try Self.copy(image, in: colorSpace)
        guard let bottom = compact.cropping(to: CGRect(
            x: 0, y: frameHeight - displacement, width: width, height: displacement
        )) else { throw LongScreenshotError.bitmap }
        let strip = try Self.copy(bottom, in: colorSpace)
        try Task.checkCancellation()
        last = compact
        strips.append(strip)
        height = nextHeight
    }

    func renderedImage() throws -> CGImage {
        let context = try Self.context(width: width, height: height, space: colorSpace)
        var top = height
        for strip in strips {
            try Task.checkCancellation()
            top -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: top, width: width, height: strip.height))
        }
        guard let image = context.makeImage() else { throw LongScreenshotError.bitmap }
        return image
    }

    private static func context(width: Int, height: Int, space: CGColorSpace) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw LongScreenshotError.bitmap
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        return context
    }

    private static func copy(_ image: CGImage, in space: CGColorSpace) throws -> CGImage {
        let context = try context(width: image.width, height: image.height, space: space)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let copy = context.makeImage() else { throw LongScreenshotError.bitmap }
        return copy
    }

    private static func signature(_ image: CGImage, columns: Int) throws -> [UInt8] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try context(width: columns, height: image.height, space: space)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: image.height))
        guard let data = context.data else { throw LongScreenshotError.bitmap }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: columns * image.height * 4))
    }

    private static func displacement(previous: CGImage, next: CGImage) throws -> Int {
        let columns = 24
        let stride = columns * 4
        let height = previous.height
        let a = try signature(previous, columns: columns)
        let b = try signature(next, columns: columns)
        func score(_ shift: Int, samples: Int) -> (mean: Double, badRows: Int, detailRows: Int, count: Int) {
            let overlap = height - shift
            let count = min(samples, overlap)
            var difference = 0
            var badRows = 0
            var detailRows = 0
            for i in 0..<count {
                let row = i * (overlap - 1) / max(1, count - 1)
                let p = (row + shift) * stride
                let q = row * stride
                var rowDifference = 0
                var low = 255
                var high = 0
                for column in 0..<columns {
                    let x = column * 4
                    let r = Int(a[p + x]), g = Int(a[p + x + 1]), blue = Int(a[p + x + 2])
                    rowDifference += abs(r - Int(b[q + x])) + abs(g - Int(b[q + x + 1])) + abs(blue - Int(b[q + x + 2]))
                    let brightness = (r + 2 * g + blue) / 4
                    low = min(low, brightness)
                    high = max(high, brightness)
                }
                difference += rowDifference
                if rowDifference > columns * 3 * 8 { badRows += 1 }
                if high - low >= 12 { detailRows += 1 }
            }
            return (Double(difference) / Double(count * columns * 3), badRows, detailRows, count)
        }

        let stationary = score(0, samples: 144)
        if stationary.mean < 0.65 && stationary.badRows == 0 { throw LongScreenshotError.unchanged }
        let minimumOverlap = max(32, (height + 3) / 4)
        var candidates: [(offset: Int, score: Double)] = []
        for shift in 1...(height - minimumOverlap) {
            if shift.isMultiple(of: 64) { try Task.checkCancellation() }
            let coarse = score(shift, samples: 24)
            if coarse.mean <= 4 { candidates.append((shift, coarse.mean)) }
        }
        candidates.sort { $0.score == $1.score ? $0.offset < $1.offset : $0.score < $1.score }
        // If many widely spaced offsets are nearly identical, do not guess.
        if candidates.count > 64, candidates[64].score <= candidates[0].score + 0.5 {
            throw LongScreenshotError.ambiguous
        }
        var matches: [(offset: Int, score: Double)] = []
        for candidate in candidates.prefix(64) {
            try Task.checkCancellation()
            let result = score(candidate.offset, samples: 144)
            guard result.mean <= 2.5, result.badRows <= max(1, result.count / 18),
                  result.detailRows >= max(4, result.count / 10) else { continue }
            matches.append((candidate.offset, result.mean))
        }
        guard let best = matches.min(by: { $0.score < $1.score }) else { throw LongScreenshotError.noOverlap }
        // Adjacent pixels can tie due to raster rounding; distant ties are
        // repeated content, not sufficient evidence of a seam.
        if matches.contains(where: { abs($0.offset - best.offset) > 2 && $0.score <= best.score + 0.55 }) {
            throw LongScreenshotError.ambiguous
        }
        return best.offset
    }
}

@MainActor
private final class LongScreenshotPanel: NSPanel {
    // Borderless chrome must still support the explicitly opened Save sheet.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LongScreenshotController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let captureNext: () async throws -> CGImage
    private var stitcher: LongScreenshotStitcher
    private var operation: Task<Void, Never>?
    private var captureTimeout: DispatchWorkItem?
    private var idleTimeout: DispatchWorkItem?
    private var savePanel: NSSavePanel?
    private var generation = 0
    private var closed = false
    private let status = NSTextField(wrappingLabelWithString: "回原页面往下滚一小段，再点「接一屏」。")
    private let count = NSTextField(labelWithString: "")
    private lazy var appendButton = NSButton(title: "接一屏", target: self, action: #selector(appendFrame))
    private lazy var copyButton = NSButton(title: "复制长图", target: self, action: #selector(copyImage))
    private lazy var saveButton = NSButton(title: "保存 PNG…", target: self, action: #selector(saveImage))

    init(first: CGImage, selection: CGRect, screen: NSScreen, captureNext: @escaping () async throws -> CGImage) throws {
        stitcher = try LongScreenshotStitcher(first: first)
        self.captureNext = captureNext
        let panel = LongScreenshotPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 148),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "长截图"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        buildUI(in: panel)
        updateControls()
        let inset = CaptureAppearance.toolbarScreenInset
        let visible = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        let size = panel.frame.size
        let centerX = min(max(selection.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let positions = [
            CGPoint(x: selection.maxX + 10, y: selection.maxY - size.height),
            CGPoint(x: selection.minX - size.width - 10, y: selection.maxY - size.height),
            CGPoint(x: centerX, y: selection.minY - size.height - 10),
            CGPoint(x: centerX, y: selection.maxY + 10)
        ]
        let point = positions.first { visible.contains(CGRect(origin: $0, size: size)) }
            ?? CGPoint(x: visible.maxX - size.width, y: visible.minY)
        panel.setFrameOrigin(point)
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI(in panel: NSPanel) {
        let host = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        host.autoresizingMask = [.width, .height]
        panel.contentView = CaptureAppearance.surfaceBackground(
            frame: host.bounds, host: host, cornerRadius: CaptureAppearance.panelCornerRadius
        )

        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "长截图")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        let close = NSButton(title: "", target: self, action: #selector(cancelCapture))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        close.toolTip = "关闭长截图（Esc）"
        close.keyEquivalent = "\u{1b}"
        CaptureAppearance.styleButton(close)
        let header = NSStackView(views: [icon, title, NSView(), count, close])
        header.spacing = CaptureAppearance.toolbarSpacing
        header.alignment = .centerY

        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        let hint = NSTextField(labelWithString: "留至少四分之一重叠，尽量避开固定栏。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        for button in [appendButton, copyButton, saveButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        appendButton.bezelColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
        let actions = NSStackView(views: [appendButton, NSView(), copyButton, saveButton])
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [header, status, hint, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            close.widthAnchor.constraint(equalToConstant: 26),
            close.heightAnchor.constraint(equalToConstant: 26),
            status.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    func present() {
        window?.orderFrontRegardless()
        armIdleTimeout()
    }

    @objc private func cancelCapture() { close() }

    func windowWillClose(_ notification: Notification) {
        closed = true
        generation &+= 1
        operation?.cancel()
        operation = nil
        captureTimeout?.cancel()
        idleTimeout?.cancel()
        if let savePanel, let window {
            window.endSheet(savePanel, returnCode: .cancel)
            savePanel.orderOut(nil)
        }
        savePanel = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func armIdleTimeout() {
        idleTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.operation == nil, self.savePanel == nil else { return }
            self.close()
        }
        idleTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeout)
    }

    private func updateControls() {
        count.stringValue = "已接 \(stitcher.frameCount) 屏 · \(stitcher.width) × \(stitcher.height) 像素"
        let ready = operation == nil && savePanel == nil && !closed
        appendButton.isEnabled = ready
        copyButton.isEnabled = ready
        saveButton.isEnabled = ready
    }

    @objc private func appendFrame() {
        guard !closed, operation == nil, savePanel == nil else { return }
        let snapshot = stitcher
        let capture = captureNext
        generation &+= 1
        let token = generation
        status.stringValue = "正在取图并找接缝…"
        operation = Task { [weak self] in
            do {
                let image = try await capture()
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    var result = snapshot
                    try result.append(image)
                    return result
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == token else { return }
                self.stitcher = result
                self.completeOperation("已接上。可以继续滚动，或复制、保存。")
            } catch {
                guard let self, !self.closed, self.generation == token else { return }
                self.completeOperation(error.localizedDescription)
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.operation != nil else { return }
            self.generation &+= 1
            self.operation?.cancel()
            self.completeOperation(LongScreenshotError.captureTimedOut.localizedDescription)
        }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        updateControls()
    }

    private func completeOperation(_ message: String) {
        captureTimeout?.cancel()
        captureTimeout = nil
        operation = nil
        status.stringValue = message
        updateControls()
        armIdleTimeout()
    }

    @objc private func copyImage() { export(to: nil) }

    @objc private func saveImage() {
        guard !closed, operation == nil, savePanel == nil, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "长截图.png"
        savePanel = panel
        updateControls()
        NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, !self.closed, let panel, self.savePanel === panel else { return }
            self.savePanel = nil
            self.updateControls()
            self.armIdleTimeout()
            if response == .OK, let url = panel.url { self.export(to: url) }
        }
    }

    private func export(to url: URL?) {
        guard !closed, operation == nil, savePanel == nil else { return }
        let snapshot = stitcher
        generation &+= 1
        let token = generation
        status.stringValue = "正在生成 PNG…"
        operation = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let data = try PNGImageEncoder.encode(snapshot.renderedImage())
                try Task.checkCancellation()
                if let url { try data.write(to: url, options: .atomic) }
                return data
            }
            do {
                let data = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, !self.closed, self.generation == token else { return }
                if url == nil {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setData(data, forType: .png) else {
                        self.completeOperation("复制失败，可以再试或保存 PNG。")
                        return
                    }
                }
                self.completeOperation(url == nil ? "已复制长图，可以粘贴了。" : "长图已保存。")
            } catch {
                guard let self, !self.closed, self.generation == token else { return }
                self.completeOperation(error.localizedDescription)
            }
        }
        updateControls()
    }
}
