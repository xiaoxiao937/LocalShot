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

    init(cgImage: CGImage, pointSize: CGSize, screenRect: CGRect? = nil) {
        self.cgImage = cgImage
        self.pointSize = CGSize(
            width: max(1, pointSize.width),
            height: max(1, pointSize.height)
        )
        self.screenRect = screenRect
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
final class CaptureCoordinator {
    private let settings: SettingsStore
    private var regionController: RegionCaptureController?
    private var editorControllers: [EditorWindowController] = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start(_ mode: CaptureMode) async {
        guard ensurePermission() else { return }
        do {
            switch mode {
            case .region:
                try await startRegionCapture()
            case .fullScreen:
                let image = try await captureDisplay(screenUnderPointer())
                openEditor(image)
            }
        } catch CaptureError.cancelled {
            return
        } catch {
            showError(error.localizedDescription)
        }
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

    private func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func captureDisplay(_ screen: NSScreen) async throws -> CapturedImage {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayNotFound
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGDisplayPixelsWide(displayID))
        configuration.height = Int(CGDisplayPixelsHigh(displayID))
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = settings.includeCursor
        configuration.ignoreShadowsSingleWindow = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedImage(cgImage: image, pointSize: screen.frame.size)
    }

    private func startRegionCapture() async throws {
        let screen = screenUnderPointer()
        // Window discovery is an enhancement to free-form selection, not a
        // prerequisite. If ScreenCaptureKit cannot enumerate windows, the
        // regular drag-to-select flow remains available.
        let candidates = (try? await windowCandidates(on: screen)) ?? []
        let controller = RegionCaptureController(screen: screen, windowCandidates: candidates)
        regionController = controller
        controller.onComplete = { [weak self] selection in
            guard let self else { return }
            self.regionController = nil
            Task { @MainActor in
                do {
                    // Give WindowServer one frame to remove the selection overlay
                    // before ScreenCaptureKit reads the selected pixels.
                    try await Task.sleep(for: .milliseconds(80))
                    let image = try await self.captureRegion(selection, on: screen)
                    self.openEditor(image)
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        }
        controller.onCancel = { [weak self] in self?.regionController = nil }
        controller.show()
    }

    private func windowCandidates(on screen: NSScreen) async throws -> [CGRect] {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayNotFound
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
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

    private func captureRegion(_ selection: CGRect, on screen: NSScreen) async throws -> CapturedImage {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayNotFound
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let displayBounds = CGRect(origin: .zero, size: screen.frame.size)
        let sourceRect = selection.integral.intersection(displayBounds)
        guard sourceRect.width >= 1, sourceRect.height >= 1 else {
            throw CaptureError.cancelled
        }

        // SCDisplay.width/height already describe pixels on current macOS.
        // sourceRect is in logical points, so NSScreen.backingScaleFactor is
        // the correct points-to-pixels multiplier for Retina output.
        let scale = max(1, screen.backingScaleFactor)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(ceil(sourceRect.width * scale)))
        configuration.height = max(1, Int(ceil(sourceRect.height * scale)))
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = settings.includeCursor
        configuration.ignoreShadowsSingleWindow = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let globalRect = CGRect(
            x: screen.frame.minX + sourceRect.minX,
            y: screen.frame.maxY - sourceRect.maxY,
            width: sourceRect.width,
            height: sourceRect.height
        )
        let pointSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        return CapturedImage(cgImage: image, pointSize: pointSize, screenRect: globalRect)
    }

    private func openEditor(_ image: CapturedImage) {
        let controller = EditorWindowController(image: image, settings: settings)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.editorControllers.removeAll { $0 === controller }
        }
        editorControllers.append(controller)
        controller.showWindow(nil)
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
