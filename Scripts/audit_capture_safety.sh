#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OVERLAY_SOURCE="$PROJECT_DIR/Sources/LocalShot/RegionCaptureController.swift"
COORDINATOR_SOURCE="$PROJECT_DIR/Sources/LocalShot/CaptureService.swift"
APP_SOURCE="$PROJECT_DIR/Sources/LocalShot/AppDelegate.swift"
HOTKEY_SOURCE="$PROJECT_DIR/Sources/LocalShot/HotKeyManager.swift"
SETTINGS_SOURCE="$PROJECT_DIR/Sources/LocalShot/SettingsStore.swift"
EDITOR_SOURCE="$PROJECT_DIR/Sources/LocalShot/EditorWindowController.swift"
OCR_SOURCE="$PROJECT_DIR/Sources/LocalShot/TextRecognitionService.swift"
APPEARANCE_SOURCE="$PROJECT_DIR/Sources/LocalShot/CaptureAppearance.swift"
LONG_SOURCE="$PROJECT_DIR/Sources/LocalShot/LongScreenshot.swift"

fail() {
    echo "截图安全审计失败：$1"
    exit 1
}

if /usr/bin/grep -REq 'runModal\(for:|\.screenSaver' "$PROJECT_DIR/Sources/LocalShot"; then
    fail "截图源码重新引入了应用级模态窗口或 screenSaver 层级"
fi

if /usr/bin/grep -Eq 'isCompleting|isInteractionEnabled' "$OVERLAY_SOURCE"; then
    fail "区域截图重新引入了模态遮罩、screenSaver 层级或禁止取消状态"
fi

for requirement in \
    'window.level = .statusBar' \
    'window.hidesOnDeactivate = true' \
    'window.ignoresMouseEvents = true' \
    'window.acceptsKeyEvents = false' \
    'NSApplication.didResignActiveNotification' \
    'deadline: .now() + 120' \
    'deadline: .now() + 2'; do
    if ! /usr/bin/grep -Fq "$requirement" "$OVERLAY_SOURCE"; then
        fail "区域遮罩缺少安全不变量：$requirement"
    fi
done
for requirement in \
    'private func isExplicitLineBreak(_ event: NSEvent)' \
    'insertText("\n", replacementRange: selectedRange())' \
    'window?.firstResponder === self, isExplicitLineBreak(event), !hasMarkedText()' \
    'inlineTextView.isHandlingMarkedTextReturn || inlineTextView.hasMarkedText()' \
    'x: sourceScreenTopLeft.x + newRect.minX' \
    'y: sourceScreenTopLeft.y - newRect.maxY' \
    'private func beginViewportMove(with event: NSEvent)' \
    'private func updateViewportMove(with event: NSEvent)' \
    'event.cgEvent?.unflippedLocation' \
    'guard !isApplyingViewportFrame else { return }' \
    'let pixelWidth = min(CGFloat(sourceImage.width), (original.width * scaleX).rounded())' \
    'viewportMoveOriginal ?? viewportResizeOriginal' \
    '移动截图范围'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "明确换行或可撤销移动取景缺少实现：$requirement"
    fi
done
if /usr/bin/grep -Fq 'markedRange().location' "$EDITOR_SOURCE"; then
    fail "不能用标记范围的位置代替 hasMarkedText() 判断组字"
fi
EDITOR_MOUSE_DOWN=$(/usr/bin/sed -n '/override func mouseDown(with event: NSEvent)/,/override func keyDown(with event: NSEvent)/p' "$EDITOR_SOURCE")
if [[ $(print -r -- "$EDITOR_MOUSE_DOWN" | /usr/bin/grep -Fc 'beginViewportMove(with: event)') -ne 2 \
      || $(print -r -- "$EDITOR_MOUSE_DOWN" | /usr/bin/grep -Fc 'performWindowDrag(with: event)') -ne 1 ]]; then
    fail "编辑中的移动/空格没有调整取景，或贴图不再独立移动"
fi
for requirement in \
    'enum Annotation: Equatable' \
    'private func recordNudgeHistory(' \
    'finishGeometryGesture(preservingKeyboardNudge: true)' \
    'timestamp - group.lastTimestamp <= 0.35' \
    'if case let .replaced(_, before, after) = entry, before == after { return }' \
    'override func menu(for event: NSEvent)' \
    '恢复自适应宽度' \
    'annotations[target.index] == target.snapshot' \
    'settings.setAnnotationStrokeWidth(widthSlider.doubleValue, for: canvas.tool)'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "撤销去空项、微调合并、文字恢复或工具线宽缺少实现：$requirement"
    fi
done
for requirement in \
    'func annotationStrokeWidth(for tool: EditorTool)' \
    'func setAnnotationStrokeWidth(_ width: CGFloat, for tool: EditorTool)' \
    'annotationStrokeWidth.arrow' \
    'annotationStrokeWidth.rectangle' \
    'annotationStrokeWidth.pen'; do
    if ! /usr/bin/grep -Fq "$requirement" "$SETTINGS_SOURCE"; then
        fail "绘图工具独立线宽或旧偏好回退缺少实现：$requirement"
    fi
done
if ! /usr/bin/grep -Fq 'settings.annotationStrokeWidth(for: tool)' "$OVERLAY_SOURCE"; then
    fail "区域工具栏未使用各工具独立线宽"
fi
for requirement in \
    'originalLayoutWidth + horizontalDelta' \
    'Task.detached(priority: .userInitiated)' \
    'showTextRecognitionProgress()' \
    'cancelTextRecognition()' \
    'onViewportChange' \
    'case viewport(before: CGRect, after: CGRect)' \
    'deleteSelectedAnnotation()'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "文字框自动排版或异步 OCR 缺少实现：$requirement"
    fi
done
for requirement in 'request.cancel()' 'request.automaticallyDetectsLanguage = true' 'private var pending: Operation?' '.now() + 25'; do
    if ! /usr/bin/grep -Fq "$requirement" "$OCR_SOURCE"; then
        fail "OCR 缺少可取消、限流或超时处理：$requirement"
    fi
done
if /usr/bin/grep -Fq 'originalSize * currentDistance / originalDistance' "$EDITOR_SOURCE"; then
    fail "文字框拖拽仍在像图片一样整体缩放字号"
fi
for requirement in \
    'enum TextLayoutMode: Equatable' \
    'private func automaticTextLayoutWidth(' \
    'inlineTextLayoutMode == .fixed' \
    'layoutManager.extraLineFragmentRect.maxY' \
    'override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange)' \
    'override func insertText(_ string: Any, replacementRange: NSRange)' \
    'override func unmarkText()' \
    'nativeTextMutationDepth == 0' \
    'textView.onLiveTextChange = nil' \
    'textView.inputContext?.invalidateCharacterCoordinates()' \
    'measuringStorage.setAttributedString(storage)' \
    'private lazy var measuringContainer: NSTextContainer' \
    'defaultLineHeight(for: font)' \
    'private final class InlineTextSurfaceBackground'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "文字伸缩、候选组字或输入布局隔离缺少实现：$requirement"
    fi
done
if /usr/bin/grep -Fq 'boundingRectForFont.height' "$EDITOR_SOURCE"; then
    fail "文字输入重新使用字体最大字形包围盒作为行高"
fi
for requirement in \
    'private func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat)' \
    'if !path.isEmpty, path.contains(point)' \
    'return [path.bounds.insetBy(dx: -2, dy: -2)]' \
    'draftInvalidationRects(for: oldValue)' \
    'if toolbarPanel.frame != toolbarFrame' \
    'if textMeasurements.count >= 64'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "箭头共享路径或标注局部更新缺少实现：$requirement"
    fi
done
ARROW_DRAFT_SOURCE=$(/usr/bin/sed -n '/if drawingTool == .arrow {/,/if drawingTool == .rectangle/p' "$EDITOR_SOURCE")
EMPTY_ARROW_GUARD=$(print -r -- "$ARROW_DRAFT_SOURCE" | /usr/bin/grep -nF 'guard !path.isEmpty else { return [] }' | /usr/bin/head -1 | /usr/bin/cut -d: -f1 || true)
ARROW_BOUNDS_READ=$(print -r -- "$ARROW_DRAFT_SOURCE" | /usr/bin/grep -nF 'path.bounds' | /usr/bin/head -1 | /usr/bin/cut -d: -f1 || true)
if [[ -z "$EMPTY_ARROW_GUARD" || -z "$ARROW_BOUNDS_READ" || "$EMPTY_ARROW_GUARD" -ge "$ARROW_BOUNDS_READ" ]]; then
    fail "箭头起笔读取空路径 bounds，可能中断后续拖动预览"
fi
if /usr/bin/grep -Eq 'arrowPath\(.*\)\.bounds' "$EDITOR_SOURCE"; then
    fail "箭头路径直接读取 bounds，缺少空路径保护"
fi
if /usr/bin/grep -Fq 'let minimumLayoutWidth = min(120' "$EDITOR_SOURCE"; then
    fail "文字输入仍保留固定的 120 点最小空白"
fi
INLINE_TEXT_SOURCE=$(/usr/bin/sed -n '/private final class InlineAnnotationTextView:/,/private final class RecognitionResultTextView:/p' "$EDITOR_SOURCE")
if print -r -- "$INLINE_TEXT_SOURCE" | /usr/bin/grep -Fq 'string: "输入文字"'; then
    fail "文字输入框仍绘制大号占位提示"
fi
if ! /usr/bin/grep -Fq 'let candidates = (try? windowCandidates(on: screen, in: content)) ?? []' "$COORDINATOR_SOURCE"; then
    fail "自动框选没有使用系统窗口候选"
fi
if /usr/bin/grep -Eq 'VNDetectRectanglesRequest|visualCandidates' "$COORDINATOR_SOURCE"; then
    fail "自动框选仍混入了视觉形状候选"
fi
if ! /usr/bin/grep -Fq 'windowCandidates.first { $0.contains(point) }' "$OVERLAY_SOURCE"; then
    fail "自动框选仍会优先选择内部最小矩形"
fi
for requirement in \
    'selectionView.onSelectionCommitted = { [weak self] in' \
    'onSelectionCommitted?()'; do
    if ! /usr/bin/grep -Fq "$requirement" "$OVERLAY_SOURCE"; then
        fail "首次圈定后没有立即交接可调整范围的编辑器：$requirement"
    fi
done

COMPLETE_CAPTURE=$(/usr/bin/sed -n '/private func completeCapture/,/private func cancelCapture/p' "$OVERLAY_SOURCE")
HANDOFF_LINE=$(print -r -- "$COMPLETE_CAPTURE" | /usr/bin/grep -n 'beginSafeHandoff()' | /usr/bin/head -1 | /usr/bin/cut -d: -f1 || true)
CALLBACK_LINE=$(print -r -- "$COMPLETE_CAPTURE" | /usr/bin/grep -n 'completion?(request)' | /usr/bin/head -1 | /usr/bin/cut -d: -f1 || true)
if [[ -z "$HANDOFF_LINE" || -z "$CALLBACK_LINE" || "$HANDOFF_LINE" -ge "$CALLBACK_LINE" ]]; then
    fail "异步截图开始前没有先将全屏遮罩降级为无输入交接层"
fi

CROP_REGION=$(/usr/bin/sed -n '/private func cropRegion/,/private func openEditor/p' "$COORDINATOR_SOURCE")
if ! print -r -- "$CROP_REGION" | /usr/bin/grep -Fq 'frozenDisplay.cgImage.cropping(to: pixelRect)'; then
    fail "区域结果没有直接从冻结底片的原始 CGImage 像素裁切"
fi
if print -r -- "$CROP_REGION" | /usr/bin/grep -Fq 'SCScreenshotManager.captureImage'; then
    fail "选区完成后重新调用了 ScreenCaptureKit，可能再次引入闪烁"
fi
if [[ $(/usr/bin/grep -Fc 'SCScreenshotManager.captureImage' "$COORDINATOR_SOURCE") -ne 1 ]]; then
    fail "截图流程绕过统一的单帧捕获入口"
fi
for requirement in \
    'NSColorPanel.colorDidChangeNotification' \
    'systemColorRelay.start(panel: panel)' \
    'systemColorRelay.stop()' \
    'onColorChange(resolved)' \
    'let panel = CapturePalettePanel(' \
    'override func mouseDown(with event: NSEvent)' \
    'NSEvent.removeMonitor(paletteClickMonitor)'; do
    if ! /usr/bin/grep -Fq "$requirement" "$APPEARANCE_SOURCE"; then
        fail "小色盘或系统颜色窗口缺少显式回传及清理：$requirement"
    fi
done
if /usr/bin/grep -Rq 'ColorDiagnostics\|LocalShotColorTrace\|diagnose-color' "$PROJECT_DIR/Sources/LocalShot"; then
    fail "临时颜色事件诊断尚未移除"
fi
for requirement in \
    'private func applyColorSelection(_ color: NSColor)' \
    'private func applyInlineColor(_ requestedColor: NSColor)' \
    'self.inlineTextView === originalView'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "文字颜色或原生撤销缺少实现：$requirement"
    fi
done
if [[ $(/usr/bin/grep -Fc 'SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)' "$COORDINATOR_SOURCE") -ne 2 ]] ||
   /usr/bin/grep -Fq 'onScreenWindowsOnly: false' "$COORDINATOR_SOURCE"; then
    fail "截图准备或长截图续拍重新枚举了不可见窗口"
fi
for requirement in \
    'styleMask: [.borderless, .nonactivatingPanel]' \
    'CaptureAppearance.surfaceBackground(' \
    'action: #selector(cancelCapture)' \
    'action: #selector(appendFrame)' \
    'let image = try await capture()' \
    'operation?.cancel()' \
    'deadline: .now() + 300' \
    'deadline: .now() + 10'; do
    if ! /usr/bin/grep -Fq "$requirement" "$LONG_SOURCE"; then
        fail "长截图缺少手动捕获、可取消或超时约束：$requirement"
    fi
done
if /usr/bin/grep -Eq 'CGEvent|AXUIElement|SCStream\(' "$LONG_SOURCE" ||
   ! /usr/bin/grep -Fq 'longScreenshotController.close()' "$COORDINATOR_SOURCE"; then
    fail "长截图引入后台录制或模拟输入，或未纳入统一取消"
fi
if ! /usr/bin/grep -Fq 'let frozenDisplay = try await captureDisplay(screen, using: content)' "$COORDINATOR_SOURCE"; then
    fail "区域遮罩出现前没有冻结整屏"
fi
if ! /usr/bin/grep -Fq 'selectionView.prepareInitialHover(at:' "$OVERLAY_SOURCE" ||
   ! /usr/bin/grep -Fq 'window.animationBehavior = .none' "$OVERLAY_SOURCE"; then
    fail "选区遮罩缺少首帧候选准备或仍有开屏动画"
fi
if ! /usr/bin/grep -Fq 'frozenDisplayImage.draw(' "$OVERLAY_SOURCE"; then
    fail "区域遮罩仍在透视实时桌面而不是显示冻结底片"
fi
if ! /usr/bin/grep -Fq 'retainAsEditorBackdrop()' "$COORDINATOR_SOURCE"; then
    fail "进入标注时没有保留冻结底片与外围暗层"
fi
if /usr/bin/grep -Fq 'leaveFrozenBackdropForWindowMove()' "$EDITOR_SOURCE"; then
    fail "移动截图仍会撤掉外围遮罩，破坏统一冻结画布"
fi
BACKDROP_RENDER=$(/usr/bin/sed -n '/if isBackdropMode {/,/guard let selection = displayedSelectionRect/p' "$OVERLAY_SOURCE")
if ! print -r -- "$BACKDROP_RENDER" | /usr/bin/grep -Fq 'NSColor.black.withAlphaComponent(0.34).setFill()' \
    || ! print -r -- "$BACKDROP_RENDER" | /usr/bin/grep -Fq 'bounds.fill()' \
    || ! print -r -- "$BACKDROP_RENDER" | /usr/bin/grep -Fq 'return'; then
    fail "编辑背景没有使用固定的整屏均匀暗层"
fi
BACKDROP_UPDATE=$(/usr/bin/sed -n '/func updateBackdropSelection(_ rect:/,/private func refreshOverlayLabels()/p' "$OVERLAY_SOURCE")
if print -r -- "$BACKDROP_UPDATE" | /usr/bin/grep -Eq 'needsDisplay|invalidateDisplay|displayIfNeeded'; then
    fail "拖动截图时仍在重绘第二套背景镂空，可能出现残影"
fi
for requirement in \
    'static func surfaceBackground(frame: NSRect, host: NSView, cornerRadius: CGFloat)' \
    'NSGlassEffectView(frame: frame)' \
    'accessibilityDisplayShouldReduceTransparency' \
    'final class CaptureGlassLabelView'; do
    if ! /usr/bin/grep -Fq "$requirement" "$APPEARANCE_SOURCE"; then
        fail "统一玻璃浮层或非交互提示组件缺少实现：$requirement"
    fi
done
if ! /usr/bin/grep -Fq 'CaptureGlassLabelView(' "$OVERLAY_SOURCE" \
    || [[ $(/usr/bin/grep -Fc 'CaptureAppearance.surfaceBackground(' "$EDITOR_SOURCE") -lt 2 ]]; then
    fail "框选提示、输入框或 OCR 没有复用玻璃组件"
fi
OVERLAY_DRAW=$(/usr/bin/sed -n '/override func draw(_ dirtyRect:/,/func enterBackdropMode()/p' "$OVERLAY_SOURCE")
if print -r -- "$OVERLAY_DRAW" | /usr/bin/grep -Eq 'addSubview|\.frame =|refreshOverlayLabels'; then
    fail "框选绘制过程变更了子视图，可能导致重绘循环或闪烁"
fi
if /usr/bin/grep -Eq 'NSGlassEffectView|surfaceBackground|CaptureGlassLabelView' "$COORDINATOR_SOURCE"; then
    fail "原始截图管线混入了玻璃 UI"
fi
for requirement in \
    'static let defaultToolRawValue = "defaultToolRawValue"' \
    'Key.defaultToolRawValue: EditorTool.move.rawValue' \
    'settings.defaultTool = EditorTool('; do
    if ! /usr/bin/grep -Fq "$requirement" "$SETTINGS_SOURCE"; then
        fail "默认工具设置缺少持久化或设置页入口：$requirement"
    fi
done
for requirement in \
    'rectangleResizeHandles(at:' \
    'resizedRectangle(' \
    'movingAnnotationIndex' \
    'cursor: .crosshair' \
    'if case .rectangle = annotations[selectedAnnotationIndex]'; do
    if ! /usr/bin/grep -Fq "$requirement" "$EDITOR_SOURCE"; then
        fail "方框移动、缩放、光标或无虚线选中态缺少实现：$requirement"
    fi
done
if ! /usr/bin/grep -Fq 'window.hidesOnDeactivate = true' "$OVERLAY_SOURCE"; then
    fail "冻结背景失焦后不会自动隐藏，存在遮挡桌面的风险"
fi

if ! /usr/bin/grep -Fq 'deadline: .now() + 10' "$COORDINATOR_SOURCE"; then
    fail "ScreenCaptureKit 区域截图缺少独立超时"
fi
if ! /usr/bin/grep -Fq 'cancelActiveCapture()' "$APP_SOURCE"; then
    fail "应用退出和全局快捷键没有统一取消当前截图"
fi
if ! /usr/bin/grep -Fq 'let activeEditors = editorControllers' "$COORDINATOR_SOURCE"; then
    fail "紧急取消没有覆盖编辑窗口和贴图"
fi
if ! /usr/bin/grep -Fq 'case emergencyCancel' "$HOTKEY_SOURCE"; then
    fail "缺少固定的全局紧急取消快捷键"
fi
if ! /usr/bin/grep -Fq 'NSButton(title: "退出 LocalShot"' "$SETTINGS_SOURCE"; then
    fail "设置页缺少明确的退出按钮"
fi
if ! /usr/bin/grep -Fq 'controller.onQuit = { [weak self] in self?.quit() }' "$APP_SOURCE"; then
    fail "设置页退出按钮没有走统一安全退出路径"
fi
if /usr/bin/grep -Fq 'if self.captureCoordinator.cancelActiveCapture() { return }' "$APP_SOURCE"; then
    fail "全局快捷键会被旧截图状态吞掉，无法执行用户本次请求"
fi
if ! /usr/bin/grep -Fq 'self.captureCoordinator.cancelPendingCapture()' "$APP_SOURCE"; then
    fail "打开设置前没有清理未完成截图"
fi
if ! /usr/bin/grep -Fq 'private var requestGeneration = 0' "$COORDINATOR_SOURCE"; then
    fail "截图请求缺少代次隔离，旧异步回调可能污染新请求"
fi
if ! /usr/bin/grep -Fq -- '--smoke-test-settings' "$PROJECT_DIR/Sources/LocalShot/AppMain.swift"; then
    fail "缺少设置窗口生命周期审计入口"
fi
if ! /usr/bin/grep -Fq -- '--smoke-test-settings' "$PROJECT_DIR/Scripts/build_app.sh"; then
    fail "构建流程没有执行设置窗口生命周期审计"
fi

echo "截图安全审计通过"
echo "- 无应用级截图 modal"
echo "- 无 screenSaver 级遮罩"
echo "- 区域截图仅在遮罩出现前捕获一次整屏"
echo "- 区域、全屏与长截图续拍仅请求可见窗口，不枚举屏幕外窗口"
echo "- 自动框选仅识别系统窗口；框选画面与结果来自同一张冻结底片"
echo "- 首次圈定立即进入编辑；移动工具/空格平移取景，贴图仍独立移动"
echo "- 普通截图直接裁切原始 CGImage 像素，不二次截图、不重采样"
echo "- 长截图手动续拍，不注入输入或连续采集；关闭及超时可取消"
echo "- 标注期间保留冻结背景与暗层，失焦自动隐藏且不接收输入"
echo "- 编辑背景固定均匀暗层，明亮截图和边框只由前景窗口绘制；拖动不刷新背景镂空"
echo "- 默认工具可持久化配置；方框支持移动、角点缩放且无蓝色虚线"
echo "- 文字输入、色盘、OCR 与框选提示复用玻璃材质；提示不在绘制中增删或移动"
echo "- 小色盘直接传递颜色；系统颜色窗口显式回传、去重并在关闭时解绑"
echo "- 文字框拖宽度自动换行；OCR 后台运行、可取消并按阅读顺序输出"
echo "- 文字输入随内容伸缩、手动宽度独立保留，末尾空行纳入高度且不绘制大号占位提示"
echo "- Shift+Return 明确插入换行，普通 Return 完成文字，候选优先交给输入法"
echo "- 未确认组字接原生更新回调；输入几何由普通容器控制，玻璃仅作非交互背景"
echo "- 输入按真实排版行高留白；测量图会话内复用，文本尺寸缓存有界且不落盘"
echo "- 渐宽实心箭头的预览、导出、命中及刷新共用路径；工具切换只擦除旧草稿"
echo "- 箭头起笔/回到原点先判空再读边界，不因空路径异常中断拖动预览"
echo "- 无变化操作不占撤销或清重做；连续方向键微调即时入栈并合并"
echo "- 各绘图工具独立记忆线宽，旧偏好作回退；文字右键恢复自适应可撤销"
echo "- 自动框选按窗口前后顺序命中，排除视觉形状候选"
echo "- 裁剪保留原始底片与标注；范围变化、删除纳入撤销"
echo "- OCR 串行、有界排队、底层取消和超时；PNG 后台编码"
echo "- 此审计只验证静态约束，不代表真实交互已验收"
echo "- 失焦、超时与全局取消兜底齐全（含编辑窗口与贴图）"
echo "- 设置页提供统一安全退出按钮"
echo "- 快捷键不被旧状态吞掉，设置窗口生命周期纳入构建门禁"
