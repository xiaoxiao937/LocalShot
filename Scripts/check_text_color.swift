import AppKit

// Only the streamed test build replaces SettingsStore's UserDefaults with this
// in-memory store. Production preferences, screen and pasteboard are untouched.
@MainActor final class ColorProbeDefaults {
    static let shared = ColorProbeDefaults()
    private var values: [String: Any] = [:]
    func register(defaults: [String: Any]) { values.merge(defaults) { current, _ in current } }
    func object(forKey key: String) -> Any? { values[key] }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@main @MainActor struct TextColorCheck {
    static func field<T>(_ object: Any, _ label: String) -> T {
        Mirror(reflecting: object).children.first(where: { $0.label == label })!.value as! T
    }

    static func equal(_ first: NSColor?, _ second: NSColor) -> Bool {
        guard let a = first?.usingColorSpace(.sRGB), let b = second.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.001
            && abs(a.greenComponent - b.greenComponent) < 0.001
            && abs(a.blueComponent - b.blueComponent) < 0.001
    }

    static func completedTextColor(_ canvas: EditorCanvasView) -> NSColor? {
        let annotations: [Annotation] = field(canvas, "annotations")
        guard let last = annotations.last, case let .text(_, _, color, _, _, _) = last else { return nil }
        return color
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func assertPNG(_ image: CGImage, contains color: NSColor) throws {
        let data = try PNGImageEncoder.encode(image)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(decoded.width == 500 && decoded.height == 400)
        let context = CGContext(data: nil, width: 500, height: 400, bitsPerComponent: 8,
                                bytesPerRow: 2000, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 500, height: 400))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let c = color.usingColorSpace(.sRGB)!
        let target = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        var matches = 0
        for pixel in 0..<(500 * 400) {
            if (0..<3).allSatisfy({ abs(Int(bytes[pixel * 4 + $0]) - target[$0]) <= 3 }) { matches += 1 }
        }
        precondition(matches > 10, "PNG lost the chosen text color")
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let context = CGContext(data: nil, width: 500, height: 400, bitsPerComponent: 8,
                                bytesPerRow: 2000, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 400))
        let panel = NSColorPanel.shared // Created but never shown or activated.
        let originalContinuous = panel.isContinuous
        for chosen in [NSColor.systemBlue, .systemGreen, .black, .white,
                       NSColor(srgbRed: 0.7, green: 0.25, blue: 0.9, alpha: 1)] {
            let editor = EditorWindowController(
                image: CapturedImage(cgImage: context.makeImage()!, pointSize: CGSize(width: 500, height: 400)),
                settings: .shared
            )
            let canvas: EditorCanvasView = field(editor, "canvas")
            let well: CaptureColorWell = field(editor, "colorWell")
            let palette = CaptureColorPaletteController(color: well.color)
            palette.onChooseColor = { well.applyPickedColor($0) }
            palette.loadView()
            palette.view.layoutSubtreeIfNeeded()
            let choices: [(String, NSColor)] = field(palette, "choices")
            let buttons = descendants(palette.view).compactMap { $0 as? CaptureColorSwatchButton }
            precondition(buttons.count == choices.count)
            for button in buttons {
                let point = palette.view.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                precondition(palette.view.hitTest(point) === button)
                button.performClick(nil)
                precondition(equal(well.color, choices[button.tag].1)
                             && equal(canvas.strokeColor, choices[button.tag].1))
            }
            let relay: CaptureSystemColorRelay = field(well, "systemColorRelay")
            panel.color = .systemRed
            var changes = 0
            relay.start(panel: panel) { color in
                changes += 1
                well.applyPickedColor(color)
            }
            panel.color = chosen
            NotificationCenter.default.post(name: NSColorPanel.colorDidChangeNotification, object: panel)
            NotificationCenter.default.post(name: NSColorPanel.colorDidChangeNotification, object: panel)
            precondition(changes == 1 && equal(well.color, chosen) && equal(canvas.strokeColor, chosen))
            canvas.tool = .text
            canvas.applyInitialGesture(.tap(CGPoint(x: 50, y: 50)), for: .text)
            let textView: NSTextView? = field(canvas, "inlineTextView")
            precondition(equal(textView?.textColor, chosen))
            textView!.insertText("文字 Test", replacementRange: NSRange(location: NSNotFound, length: 0))
            precondition(equal(textView?.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, chosen))
            let undo = textView!.undoManager!
            undo.removeAllActions()
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo.beginUndoGrouping()
            well.applyPickedColor(.systemRed)
            undo.endUndoGrouping()
            precondition(equal(textView!.textColor, .systemRed))
            undo.undo()
            precondition(equal(textView!.textColor, chosen) && equal(well.color, chosen))
            undo.redo()
            precondition(equal(textView!.textColor, .systemRed))
            _ = canvas.textView(textView!, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            canvas.tool = .move
            well.applyPickedColor(chosen)
            precondition(equal(canvas.selectedAnnotationColor, chosen))
            canvas.undoLast()
            precondition(equal(completedTextColor(canvas), .systemRed))
            canvas.redoLast()
            precondition(equal(completedTextColor(canvas), chosen))
            precondition(equal(canvas.strokeColor, chosen) && equal(SettingsStore.shared.annotationColor, chosen))
            try assertPNG(canvas.flattenedCGImage()!, contains: chosen)
            relay.stop()
            precondition(panel.isContinuous == originalContinuous)
            panel.color = .systemOrange
            NotificationCenter.default.post(name: NSColorPanel.colorDidChangeNotification, object: panel)
            precondition(changes == 1 && equal(completedTextColor(canvas), chosen))
            editor.close()
        }
        precondition(!panel.isVisible)
        print("文字颜色组件通过：10 色小色盘命中与回调、系统色回传与去重、蓝/绿/黑/白/自定义色、新建与输入中改色、已完成文字改色、撤销重做、PNG 像素、关闭后不回传")
    }
}
