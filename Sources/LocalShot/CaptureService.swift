import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureMode {
    case region
    case fullScreen
}

struct CapturedImage {
    let cgImage: CGImage
    let pointSize: CGSize
    let screenRect: CGRect?
    // Shared immutable source permits changing the viewport after annotations
    // without recapturing the desktop or destroying out-of-bounds content.
    let sourceCGImage: CGImage?
    let sourcePointSize: CGSize?
    let selectionRect: CGRect?

    init(
        cgImage: CGImage,
        pointSize: CGSize,
        screenRect: CGRect? = nil,
        sourceCGImage: CGImage? = nil,
        sourcePointSize: CGSize? = nil,
        selectionRect: CGRect? = nil
    ) {
        self.cgImage = cgImage
        self.pointSize = CGSize(
            width: max(1, pointSize.width),
            height: max(1, pointSize.height)
        )
        self.screenRect = screenRect
        self.sourceCGImage = sourceCGImage
        self.sourcePointSize = sourcePointSize
        self.selectionRect = selectionRect
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要屏幕录制权限才能截图。"
        case .displayNotFound: return "无法识别当前显示器。"
        case .cancelled: return "已取消。"
        }
    }
}

@MainActor
final class CaptureCoordinator: NSObject {
    private let settings: SettingsStore
    private var preparationTask: Task<Void, Never>?
    private var preparationTimeout: DispatchWorkItem?
    private var regionController: RegionCaptureController?
    private var longScreenshotController: LongScreenshotController?
    private var editorBackdrop: RegionCaptureController?
    private var regionCaptureTask: Task<Void, Never>?
    private var regionCaptureTimeout: DispatchWorkItem?
    private var regionCaptureGeneration = 0
    private var requestGeneration = 0
    private var editorControllers: [EditorWindowController] = []

    var pinnedImageCount: Int { editorControllers.filter(\.isPinned).count }

    func closePinnedImages() {
        let pinned = editorControllers.filter(\.isPinned)
        pinned.forEach { $0.close() }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(workspaceSuspending), name: name, object: nil)
        }
    }

    func start(_ mode: CaptureMode) async {
        // A requested action replaces only an unfinished capture operation and
        // must still execute on this same key press. The previous implementation
        // returned after cleanup, making a stale controller swallow every
        // region/settings shortcut that followed it.
        cancelPendingCapture()
        requestGeneration &+= 1
        let generation = requestGeneration
        guard ensurePermission() else { return }
        // The permission dialog runs a nested event loop. A shortcut or cancel
        // received there can supersede this request before the dialog returns.
        guard requestGeneration == generation else { return }
        // A new capture owns one editing session. Pinned images remain separate
        // and are excluded from capture at the ScreenCaptureKit filter below.
        let editors = editorControllers.filter { !$0.isPinned }
        editors.forEach { $0.close() }
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareCapture(mode, generation: generation)
        }
        preparationTask = work
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.requestGeneration == generation,
                      self.preparationTask != nil else { return }
                self.cancelPendingCapture()
                self.showError("截图准备超过 10 秒没有响应，已取消。你可以重新截图。")
            }
        }
        preparationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        await work.value
    }

    private func prepareCapture(_ mode: CaptureMode, generation: Int) async {
        defer {
            if requestGeneration == generation {
                preparationTimeout?.cancel()
                preparationTimeout = nil
                preparationTask = nil
            }
        }
        do {
            try Task.checkCancellation()
            switch mode {
            case .region:
                try await startRegionCapture(generation: generation)
            case .fullScreen:
                guard let screen = screenUnderPointer() else { throw CaptureError.displayNotFound }
                let image = try await captureDisplay(screen)
                try Task.checkCancellation()
                guard requestGeneration == generation else { return }
                let backdrop = RegionCaptureController(
                    screen: screen, windowCandidates: [], frozenDisplay: image,
                    defaultTool: settings.defaultTool, settings: settings
                )
                regionController = backdrop
                backdrop.showEditorBackdrop(selection: screen.frame)
                let editor = makeEditor(image)
                attachBackdrop(backdrop, to: editor)
                presentEditor(editor)
            }
        } catch CaptureError.cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            showError(error.localizedDescription)
        }
    }

    @discardableResult
    func cancelPendingCapture() -> Bool {
        var didCancel = false
        requestGeneration &+= 1
        if let longScreenshotController {
            self.longScreenshotController = nil
            longScreenshotController.close()
            didCancel = true
        }
        if let preparationTask {
            self.preparationTask = nil
            preparationTask.cancel()
            didCancel = true
        }
        preparationTimeout?.cancel()
        preparationTimeout = nil
        if let regionController {
            self.regionController = nil
            regionController.cancel()
            didCancel = true
        }
        if let regionCaptureTask {
            regionCaptureGeneration &+= 1
            self.regionCaptureTask = nil
            regionCaptureTask.cancel()
            didCancel = true
        }
        if let regionCaptureTimeout {
            regionCaptureTimeout.cancel()
            self.regionCaptureTimeout = nil
            didCancel = true
        }
        return didCancel
    }

    @discardableResult
    func cancelActiveCapture() -> Bool {
        var didCancel = cancelPendingCapture()
        if let editorBackdrop {
            finishRegionHandoff(editorBackdrop)
            didCancel = true
        }
        // The emergency path must also release editor and pinned-image windows.
        // Keeping this in the same coordinator-level cancellation routine means
        // the fixed global shortcut can recover from failures in either phase of
        // the screenshot flow, not only from the full-screen selection overlay.
        let activeEditors = editorControllers
        editorControllers.removeAll()
        if !activeEditors.isEmpty {
            didCancel = true
            activeEditors.forEach {
                $0.onClose = nil
                $0.close()
            }
        }
        return didCancel
    }

    @objc private func workspaceSuspending(_ notification: Notification) {
        cancelActiveCapture()
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        // Existing pixel-to-point coordinates are no longer valid after a
        // display is unplugged or its scaling changes. Close safely, then let
        // the next shortcut obtain a new screen and fresh native-size frame.
        cancelActiveCapture()
    }

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "LocalShot 只在你主动截图时读取屏幕，图像不会上传。授权后可能需要重新打开应用。"
        alert.addButton(withTitle: "申请权限")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if CGRequestScreenCaptureAccess() { return true }
        showError("权限尚未开启。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 LocalShot。")
        return false
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
    }

    private func captureDisplay(_ screen: NSScreen, using suppliedContent: SCShareableContent? = nil,
                                includeCursor: Bool? = nil) async throws -> CapturedImage {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayNotFound
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content: SCShareableContent
        if let suppliedContent {
            content = suppliedContent
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let scale = max(1, screen.backingScaleFactor)
        let configuration = SCStreamConfiguration()
        // Region capture uses this exact points-to-pixels relationship and is
        // known to preserve Retina detail. Keep the frozen display on the same
        // grid so the later crop is a raw CGImage crop, never a resample.
        configuration.width = max(1, Int(ceil(screen.frame.width * scale)))
        configuration.height = max(1, Int(ceil(screen.frame.height * scale)))
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = includeCursor ?? settings.includeCursor
        configuration.ignoreShadowsSingleWindow = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return CapturedImage(cgImage: image, pointSize: screen.frame.size, screenRect: screen.frame)
    }

    private func startRegionCapture(generation: Int) async throws {
        guard let screen = screenUnderPointer() else { throw CaptureError.displayNotFound }
        // Prepare window metadata before freezing. Reuse it for capture so
        // there is no second async enumeration between freeze and first paint.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        let candidates = (try? windowCandidates(on: screen, in: content)) ?? []
        let frozenDisplay = try await captureDisplay(screen, using: content)
        try Task.checkCancellation()
        guard requestGeneration == generation else { return }
        let controller = RegionCaptureController(
            screen: screen,
            windowCandidates: candidates,
            frozenDisplay: frozenDisplay,
            defaultTool: settings.defaultTool,
            settings: settings
        )
        regionController = controller
        controller.onComplete = { [weak self, weak controller] request in
            guard let self,
                  let controller,
                  self.requestGeneration == generation else { return }
            self.beginRegionCapture(
                request,
                on: screen,
                frozenDisplay: frozenDisplay,
                requestGeneration: generation,
                handoffController: controller
            )
        }
        controller.onCancel = { [weak self, weak controller] in
            if let self, let controller, self.regionController === controller {
                self.regionController = nil
            }
        }
        controller.show()
    }

    private func beginRegionCapture(
        _ request: RegionCaptureRequest,
        on screen: NSScreen,
        frozenDisplay: CapturedImage,
        requestGeneration activeRequestGeneration: Int,
        handoffController: RegionCaptureController
    ) {
        guard requestGeneration == activeRequestGeneration else { return }
        regionCaptureTask?.cancel()
        regionCaptureTimeout?.cancel()
        regionCaptureGeneration &+= 1
        let generation = regionCaptureGeneration
        let timeout = DispatchWorkItem { [weak self, weak handoffController] in
            Task { @MainActor in
                guard let self,
                      self.regionCaptureGeneration == generation,
                      self.regionCaptureTask != nil else { return }
                let timedOutTask = self.regionCaptureTask
                self.regionCaptureGeneration &+= 1
                self.regionCaptureTask = nil
                self.regionCaptureTimeout = nil
                timedOutTask?.cancel()
                self.finishRegionHandoff(handoffController)
                self.showError("截图服务超过 10 秒没有响应。本次截图已安全取消，你可以立即重试。")
            }
        }
        regionCaptureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        regionCaptureTask = Task { @MainActor [weak self, weak handoffController] in
            guard let self, let handoffController else { return }
            defer {
                if self.regionCaptureGeneration == generation {
                    self.regionCaptureTimeout?.cancel()
                    self.regionCaptureTimeout = nil
                    self.regionCaptureTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                // Do not ask WindowServer for another frame. Cropping the raw
                // frozen CGImage keeps the pixels identical to what the user
                // selected and removes the capture-time window transition.
                let image = try self.cropRegion(
                    request.selection,
                    from: frozenDisplay,
                    on: screen
                )
                try Task.checkCancellation()
                guard self.regionCaptureGeneration == generation,
                      self.requestGeneration == activeRequestGeneration else { return }
                self.clearRegionCaptureState(for: generation)
                let editor = self.makeEditor(image)
                switch request.action {
                case .pin, .finish:
                    self.presentEditor(editor, initialAction: request.action)
                    self.finishRegionHandoff(handoffController)
                default:
                    // Keep the same frozen display and dimming behind the
                    // editor. The selected pixels are identical, so entering
                    // annotation is a state change inside one visual surface,
                    // not a desktop/editor window flash.
                    handoffController.retainAsEditorBackdrop()
                    self.attachBackdrop(handoffController, to: editor)
                    self.presentEditor(editor, initialAction: request.action)
                }
            } catch is CancellationError {
                self.clearRegionCaptureState(for: generation)
                self.finishRegionHandoff(handoffController)
                return
            } catch {
                guard self.regionCaptureGeneration == generation,
                      self.requestGeneration == activeRequestGeneration else { return }
                self.clearRegionCaptureState(for: generation)
                self.finishRegionHandoff(handoffController)
                self.showError(error.localizedDescription)
            }
        }
    }

    private func clearRegionCaptureState(for generation: Int) {
        guard regionCaptureGeneration == generation else { return }
        regionCaptureTimeout?.cancel()
        regionCaptureTimeout = nil
        regionCaptureTask = nil
    }

    private func finishRegionHandoff(_ controller: RegionCaptureController?) {
        controller?.dismissHandoff()
        if let controller, regionController === controller {
            regionController = nil
        }
        if let controller, editorBackdrop === controller {
            editorBackdrop = nil
        }
    }

    private func attachBackdrop(_ backdrop: RegionCaptureController, to editor: EditorWindowController) {
        if regionController === backdrop { regionController = nil }
        editorBackdrop = backdrop
        editor.prepareForFrozenBackdrop()
        editor.onPresentationActiveChange = { [weak backdrop] active in
            backdrop?.setBackdropVisible(active)
        }
        editor.onFrameChange = { [weak backdrop] frame in
            backdrop?.updateBackdropSelection(to: frame)
        }
        editor.onBackdropDismissRequest = { [weak self, weak backdrop] in
            self?.finishRegionHandoff(backdrop)
        }
        let existingClose = editor.onClose
        editor.onClose = { [weak self, weak backdrop] in
            self?.finishRegionHandoff(backdrop)
            existingClose?()
        }
    }

    private func windowCandidates(on screen: NSScreen, in content: SCShareableContent) throws -> [CGRect] {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayNotFound
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayFrame = display.frame
        let localDisplayBounds = CGRect(origin: .zero, size: screen.frame.size)
        var seenFrames = Set<String>()

        // Quartz returns on-screen windows front to back. Use that order for
        // hit testing while keeping ScreenCaptureKit as the source of each
        // candidate's geometry and ownership information.
        let frontToBackInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let frontToBackRanks: [CGWindowID: Int] = Dictionary(
            uniqueKeysWithValues: frontToBackInfo.enumerated().compactMap { index, info in
                guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
                return (CGWindowID(number.uint32Value), index)
            }
        )
        let orderedWindows = content.windows.enumerated().sorted { lhs, rhs in
            let lhsRank = frontToBackRanks[lhs.element.windowID] ?? Int.max
            let rhsRank = frontToBackRanks[rhs.element.windowID] ?? Int.max
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)

        return orderedWindows.compactMap { window in
            guard let owningApplication = window.owningApplication,
                  frontToBackRanks.isEmpty || frontToBackRanks[window.windowID] != nil,
                  window.isOnScreen,
                  window.windowLayer == 0,
                  owningApplication.processID != ownPID,
                  window.frame.width >= 80,
                  window.frame.height >= 60 else {
                return nil
            }

            let visibleFrame = window.frame.intersection(displayFrame)
            guard !visibleFrame.isNull,
                  visibleFrame.width >= 40,
                  visibleFrame.height >= 40 else {
                return nil
            }

            let localFrame = CGRect(
                x: visibleFrame.minX - displayFrame.minX,
                y: visibleFrame.minY - displayFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height
            ).integral.intersection(localDisplayBounds)
            guard !localFrame.isNull, localFrame.width >= 40, localFrame.height >= 40 else {
                return nil
            }

            let frameKey = "\(Int(localFrame.minX)),\(Int(localFrame.minY)),\(Int(localFrame.width)),\(Int(localFrame.height))"
            guard seenFrames.insert(frameKey).inserted else { return nil }
            return localFrame
        }
    }

    private func cropRegion(
        _ selection: CGRect,
        from frozenDisplay: CapturedImage,
        on screen: NSScreen
    ) throws -> CapturedImage {
        let displayBounds = CGRect(origin: .zero, size: frozenDisplay.pointSize)
        let sourceRect = selection.integral.intersection(displayBounds)
        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw CaptureError.cancelled
        }
        let scaleX = CGFloat(frozenDisplay.cgImage.width) / frozenDisplay.pointSize.width
        let scaleY = CGFloat(frozenDisplay.cgImage.height) / frozenDisplay.pointSize.height
        let pixelMinX = floor(sourceRect.minX * scaleX)
        let pixelMinY = floor(sourceRect.minY * scaleY)
        let pixelMaxX = ceil(sourceRect.maxX * scaleX)
        let pixelMaxY = ceil(sourceRect.maxY * scaleY)
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: frozenDisplay.cgImage.width,
            height: frozenDisplay.cgImage.height
        )
        let pixelRect = CGRect(
            x: pixelMinX,
            y: pixelMinY,
            width: pixelMaxX - pixelMinX,
            height: pixelMaxY - pixelMinY
        ).intersection(imageBounds)
        guard !pixelRect.isNull,
              pixelRect.width >= 1,
              pixelRect.height >= 1,
              let image = frozenDisplay.cgImage.cropping(to: pixelRect) else {
            throw CaptureError.cancelled
        }
        let globalRect = CGRect(
            x: screen.frame.minX + sourceRect.minX,
            y: screen.frame.maxY - sourceRect.maxY,
            width: sourceRect.width,
            height: sourceRect.height
        )
        return CapturedImage(
            cgImage: image, pointSize: sourceRect.size, screenRect: globalRect,
            sourceCGImage: frozenDisplay.cgImage,
            sourcePointSize: frozenDisplay.pointSize,
            selectionRect: sourceRect
        )
    }

    private func openEditor(_ image: CapturedImage, initialAction: RegionCaptureAction? = nil) {
        presentEditor(makeEditor(image), initialAction: initialAction)
    }

    private func makeEditor(_ image: CapturedImage) -> EditorWindowController {
        let controller = EditorWindowController(image: image, settings: settings)
        controller.onLongScreenshot = { [weak self, weak controller] seed in
            guard let self, let controller else { throw CaptureError.cancelled }
            try self.beginLongScreenshot(seed, from: controller)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.editorControllers.removeAll { $0 === controller }
        }
        editorControllers.append(controller)
        return controller
    }

    private func beginLongScreenshot(_ seed: CapturedImage, from editor: EditorWindowController) throws {
        guard longScreenshotController == nil,
              let area = seed.screenRect, let source = seed.sourceCGImage,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.insetBy(dx: -0.01, dy: -0.01).contains(area)
              }) else { throw CaptureError.displayNotFound }
        let displayFrame = screen.frame
        let width = seed.cgImage.width
        let height = seed.cgImage.height
        let displayPixelWidth = source.width
        let displayPixelHeight = source.height
        let controller = try LongScreenshotController(first: seed.cgImage, selection: area, screen: screen) { [weak self] in
            guard let self else { throw CaptureError.cancelled }
            // Explicit “接一屏” is the only path to this callback. Own
            // windows are excluded by captureDisplay's ScreenCaptureKit filter.
            let frame = try await self.captureDisplay(screen, includeCursor: false)
            try Task.checkCancellation()
            guard frame.screenRect == displayFrame, frame.cgImage.width == displayPixelWidth,
                  frame.cgImage.height == displayPixelHeight else { throw LongScreenshotError.changedSize }
            let sx = CGFloat(frame.cgImage.width) / frame.pointSize.width
            let sy = CGFloat(frame.cgImage.height) / frame.pointSize.height
            guard abs(area.width * sx - CGFloat(width)) <= 1,
                  abs(area.height * sy - CGFloat(height)) <= 1 else { throw LongScreenshotError.changedSize }
            let pixels = CGRect(x: ((area.minX - displayFrame.minX) * sx).rounded(),
                                y: ((displayFrame.maxY - area.maxY) * sy).rounded(),
                                width: CGFloat(width), height: CGFloat(height))
            let frameBounds = CGRect(x: 0, y: 0, width: frame.cgImage.width, height: frame.cgImage.height)
            guard frameBounds.contains(pixels), let cropped = frame.cgImage.cropping(to: pixels) else {
                throw LongScreenshotError.changedSize
            }
            return cropped
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.longScreenshotController === controller else { return }
            self.longScreenshotController = nil
        }
        // Release the frozen overlay so the original app can scroll normally.
        editor.close()
        longScreenshotController = controller
        controller.present()
    }

    private func presentEditor(
        _ controller: EditorWindowController,
        initialAction: RegionCaptureAction? = nil
    ) {
        if let initialAction {
            switch initialAction {
            case .edit:
                // Configure the chosen tool and its first annotation while the
                // window is still hidden. The first visible editor frame is
                // therefore already final instead of flashing through Move.
                controller.perform(initialAction)
                controller.showWindow(nil)
            case .recognizeText, .pin, .save, .finish:
                controller.showWindow(nil)
                controller.perform(initialAction)
            }
        } else {
            controller.showWindow(nil)
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = message
        alert.runModal()
    }
}
