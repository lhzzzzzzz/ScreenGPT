import AppKit
import SwiftUI
import ScreenCaptureKit
import ScreenGPTCore

@MainActor final class CaptureCoordinator {
    private var panels: [CapturePanel] = []
    private var session: CaptureSession?
    private var capturing = false
    private var generation = UUID()
    private var screenObserver: NSObjectProtocol?
    let preferences: Preferences
    let account: ChatGPTAccount
    let history: HistoryStore
    var showSettings: (() -> Void)?
    var reportError: ((String) -> Void)?
    init(preferences: Preferences, account: ChatGPTAccount, history: HistoryStore) {
        self.preferences = preferences; self.account = account; self.history = history
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
    var isActive: Bool { capturing || !panels.isEmpty }
    func close() {
        generation = UUID(); capturing = false
        session?.reset(); session = nil
        panels.forEach { $0.orderOut(nil); $0.contentView = nil; $0.close() }; panels.removeAll()
    }
    func capture(preview: Bool = false) async {
        if isActive { close(); return }
        if !preview && !CGPreflightScreenCaptureAccess() { reportError?(L("请先允许屏幕录制。ScreenGPT 只在你按下快捷键时截图。", "Allow screen recording first. ScreenGPT captures only when you start a selection.")); showSettings?(); return }
        capturing = true; let version = UUID(); generation = version
        do {
            let frames: [(CGRect, CGImage)]
            if preview, let screen = NSScreen.main { frames = [(screen.frame, PreviewDocument.image(size: screen.frame.size))] }
            else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let tasks = NSScreen.screens.compactMap { screen -> Task<(CGRect, CGImage), Error>? in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return nil }
                    let frame = screen.frame, scale = screen.backingScaleFactor
                    return Task { @MainActor in
                        let config = SCStreamConfiguration()
                        config.width = Int(frame.width * scale)
                        config.height = Int(frame.height * scale)
                        config.showsCursor = false; config.capturesAudio = false
                        // The compositor may still retain a just-hidden settings window.
                        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return (frame, image)
                    }
                }
                var results: [(CGRect, CGImage)] = []
                do { for task in tasks { results.append(try await task.value) } }
                catch { tasks.forEach { $0.cancel() }; throw error }
                frames = results
            }
            guard generation == version else { return }
            guard !frames.isEmpty else { throw AppFailure(L("没有找到可截取的显示器。", "No display is available to capture.")) }
            let session = CaptureSession(preferences: preferences, account: account, history: history)
            self.session = session; session.preview = preview
            session.close = { [weak self] in self?.close() }
            session.settings = { [weak self] in self?.close(); self?.showSettings?() }
            session.reselect = { [weak self, weak session] in
                session?.reset(); session?.selectionLocked = false
                self?.panels.compactMap { $0.contentView as? CaptureCanvas }.forEach { $0.clearSelection() }
            }
            for (frame, image) in frames {
                let panel = CapturePanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                // Keep the capture above applications while allowing native language menus above it.
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
                panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
                let canvas = CaptureCanvas(image: image, session: session, dim: preferences.dim, glass: preferences.material == "glass")
                canvas.frame = NSRect(origin: .zero, size: frame.size)
                canvas.onSelect = { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.panels.compactMap { $0.contentView as? CaptureCanvas }.filter { $0 !== canvas }.forEach { $0.clearSelection() }
                    self.panels.forEach { panel in
                        if let view = panel.contentView { panel.invalidateCursorRects(for: view) }
                    }
                }
                panel.contentView = canvas; panel.onEscape = { [weak self] in self?.close() }
                panels.append(panel)
            }
            NSApp.activate(ignoringOtherApps: true)
            panels.forEach { $0.orderFrontRegardless() }
            let mouse = NSEvent.mouseLocation
            (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
            capturing = false
        } catch {
            guard generation == version else { return }
            close(); reportError?(L("无法截取屏幕：\(error.localizedDescription)", "Could not capture the screen: \(error.localizedDescription)")); showSettings?()
        }
    }
}
final class CapturePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
@MainActor final class CaptureCanvas: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    let image: CGImage
    let session: CaptureSession
    let dim: Double
    let glass: Bool
    var selection: CGRect?
    private enum Gesture {
        case create(CGPoint)
        case edit(SelectionDrag, CGRect, CGPoint)
    }
    private var gesture: Gesture?
    private var selectionChanged = false
    var onSelect: (() -> Void)?
    private var toolbar: NSHostingView<CaptureToolbar>?
    private var result: NSHostingView<AnswerPanel>?
    private var dragHandle: PanelDragHandle?
    private var resultOrigin: CGPoint?
    private var dragOrigin: CGPoint?
    init(image: CGImage, session: CaptureSession, dim: Double, glass: Bool) {
        self.image = image; self.session = session; self.dim = dim; self.glass = glass
        super.init(frame: .zero)
        setAccessibilityLabel(L("拖动鼠标框选，按 Escape 退出", "Drag to select an area. Press Escape to close."))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Hosting views can have transparent padding. It must never fall through to the canvas.
        let surfaces: [NSView?] = [dragHandle, result, toolbar]
        for view in surfaces.compactMap({ $0 }) where !view.isHidden && view.frame.contains(local) {
            return view.hitTest(local) ?? view
        }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: session.selectionLocked ? .arrow : .crosshair)
        if session.selectionLocked, let selection {
            addCursorRect(selection, cursor: .openHand)
            addCursorRect(CGRect(x: selection.minX - 8, y: selection.minY, width: 16, height: selection.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: selection.maxX - 8, y: selection.minY, width: 16, height: selection.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: selection.minX, y: selection.minY - 8, width: selection.width, height: 16), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: selection.minX, y: selection.maxY - 8, width: selection.width, height: 16), cursor: .resizeUpDown)
            for (handle, point) in SelectionGeometry.handlePoints(for: selection) {
                let cursor: NSCursor
                switch handle {
                case .top, .bottom: cursor = .resizeUpDown
                case .left, .right: cursor = .resizeLeftRight
                default: cursor = .crosshair
                }
                addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16), cursor: cursor)
            }
        }
        if let toolbar { addCursorRect(toolbar.frame, cursor: .arrow) }
        if let result { addCursorRect(result.frame, cursor: .arrow) }
        if let dragHandle { addCursorRect(dragHandle.frame, cursor: .openHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let mask = NSBezierPath(rect: bounds)
        if let selection { mask.appendRect(selection) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(dim).setFill(); mask.fill()
        if let rect = selection {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)); border.lineWidth = 1; border.stroke()
            for (_, point) in SelectionGeometry.handlePoints(for: rect) {
                NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
            }
        } else if !session.selectionLocked {
            let text = session.preview ? L("界面预览 · 拖动框选 · Esc 退出", "Preview · Drag to select · Esc to close") : L("拖动框选 · Esc 退出", "Drag to select · Esc to close")
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attrs)
            let pill = CGRect(x: (bounds.width - size.width) / 2 - 22, y: 42, width: size.width + 44, height: 42)
            NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: pill, xRadius: 21, yRadius: 21).fill()
            (text as NSString).draw(at: CGPoint(x: pill.minX + 22, y: pill.minY + 12), withAttributes: attrs)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        let surfaces: [NSView?] = [toolbar, result]
        guard !surfaces.compactMap({ $0 }).contains(where: { !$0.isHidden && $0.frame.contains(point) }) else { return }
        window?.makeKey(); window?.makeFirstResponder(self)
        selectionChanged = false
        if session.selectionLocked {
            guard let selection, let drag = SelectionGeometry.hitTest(point, selection: selection) else { return }
            gesture = .edit(drag, selection, point)
        } else {
            session.reset(); clearSelection()
            gesture = .create(point); selection = CGRect(origin: point, size: .zero)
            needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) { updateSelection(event) }
    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        updateSelection(event); self.gesture = nil
        if case .edit = gesture, !selectionChanged { return }
        guard let selection, selection.width >= 12, selection.height >= 12 else {
            if session.selectionLocked { session.reselect?() } else { clearSelection() }
            return
        }
        let rect = OverlayLayout.cropRect(selection: selection, viewSize: bounds.size, pixelSize: CGSize(width: image.width, height: image.height))
        guard let crop = image.cropping(to: rect), let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else { session.reselect?(); return }
        session.select(image: png)
        session.selectionLocked = true; onSelect?()
        session.reveal = { [weak self] in self?.showResult() }
        session.move = { [weak self] offset, finished in self?.moveResult(offset, finished: finished) }
        if toolbar == nil {
            let toolbar = CaptureHostingView(rootView: CaptureToolbar(session: session, glass: glass))
            self.toolbar = toolbar; addSubview(toolbar)
        }
        toolbar?.isHidden = false
        setAccessibilityLabel(L("已框选；拖动内部移动，拖动边缘或角点调整大小；点击重新框选重画；Escape 退出", "Selected. Drag inside to move; drag an edge or corner to resize. Choose Reselect to draw again. Escape to close."))
        arrange(); needsDisplay = true
    }
    private func updateSelection(_ event: NSEvent) {
        guard let gesture else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch gesture {
        case .create(let start):
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
        case .edit(let drag, let original, let start):
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            guard selectionChanged || abs(offset.width) >= 2 || abs(offset.height) >= 2 else { return }
            let updated = SelectionGeometry.applying(drag, to: original, translation: offset, in: bounds)
            guard updated != selection else { return }
            if !selectionChanged {
                session.reset(); clearResult(); toolbar?.isHidden = true; selectionChanged = true
            }
            selection = updated
        }
        needsDisplay = true
    }
    func clearSelection() {
        selection = nil; gesture = nil; selectionChanged = false; toolbar?.removeFromSuperview(); toolbar = nil
        clearResult(); needsDisplay = true
        setAccessibilityLabel(session.selectionLocked ? L("已在另一显示器框选", "An area is selected on another display.") : L("拖动鼠标框选，按 Escape 退出", "Drag to select an area. Press Escape to close."))
        window?.invalidateCursorRects(for: self)
    }
    private func clearResult() {
        result?.removeFromSuperview(); result = nil; resultOrigin = nil; dragOrigin = nil; needsDisplay = true
        dragHandle?.removeFromSuperview(); dragHandle = nil
    }
    private func showResult() {
        if result == nil {
            let host = CaptureHostingView(rootView: AnswerPanel(session: session, glass: glass)); result = host; addSubview(host)
            let handle = PanelDragHandle(); handle.move = { [weak self] in self?.moveResult($0, finished: $1) }
            dragHandle = handle; addSubview(handle)
        }
        arrange()
    }
    private func arrange() {
        guard let selection else { return }
        let layout = OverlayLayout.arrange(selection: selection, bounds: bounds, resultSize: CGSize(width: 392, height: session.composerExpanded ? 552 : 436), toolbarSize: CGSize(width: 540, height: 52))
        toolbar?.frame = layout.toolbar
        var origin = resultOrigin ?? layout.result.origin
        origin.x = min(max(12, origin.x), max(12, bounds.width - layout.result.width - 12))
        origin.y = min(max(12, origin.y), max(12, bounds.height - layout.result.height - 12))
        result?.frame = CGRect(origin: origin, size: layout.result.size)
        if resultOrigin != nil { resultOrigin = origin }
        updateDragHandle()
        window?.invalidateCursorRects(for: self)
    }
    private func moveResult(_ offset: CGSize, finished: Bool) {
        guard let result else { return }
        let start = dragOrigin ?? result.frame.origin; dragOrigin = start
        let origin = CGPoint(x: min(max(12, start.x + offset.width), max(12, bounds.width - result.frame.width - 12)), y: min(max(12, start.y + offset.height), max(12, bounds.height - result.frame.height - 12)))
        result.setFrameOrigin(origin); resultOrigin = origin; updateDragHandle()
        if finished { dragOrigin = nil }; window?.invalidateCursorRects(for: self)
    }
    private func updateDragHandle() {
        if let result { dragHandle?.frame = CGRect(x: result.frame.minX, y: result.frame.minY, width: result.frame.width, height: 51) }
    }
    private func clamped(_ point: CGPoint) -> CGPoint { CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height)) }
}

// Accept the first click even when another application was previously active.
// The canvas hit-test and mouseDown guard protect the surface's padding.
final class CaptureHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PanelDragHandle: NSView {
    var move: ((CGSize, Bool) -> Void)?
    private var origin: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow; NSCursor.closedHand.set() }
    override func mouseDragged(with event: NSEvent) { update(event, finished: false) }
    override func mouseUp(with event: NSEvent) { update(event, finished: true); origin = nil; NSCursor.openHand.set() }
    private func update(_ event: NSEvent, finished: Bool) {
        guard let origin else { return }; let point = event.locationInWindow
        move?(CGSize(width: point.x - origin.x, height: origin.y - point.y), finished)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

enum PreviewDocument {
    static func image(size: CGSize) -> CGImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.87, green: 0.91, blue: 0.90, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        let paper = CGRect(x: size.width * 0.16, y: size.height * 0.16, width: size.width * 0.64, height: size.height * 0.7)
        NSColor.white.setFill(); NSBezierPath(roundedRect: paper, xRadius: 18, yRadius: 18).fill()
        let text = "GEOMETRY / 01\n\nRead the diagram.\nUnderstand the relationship.\n\nA right triangle has legs of length 3 and 4.\nFind the length of its hypotenuse."
        (text as NSString).draw(in: paper.insetBy(dx: 48, dy: 48), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1)])
        let p = CGPoint(x: paper.minX + 60, y: paper.minY + 60)
        let triangle = NSBezierPath(); triangle.move(to: p); triangle.line(to: CGPoint(x: p.x + 240, y: p.y)); triangle.line(to: CGPoint(x: p.x, y: p.y + 180)); triangle.close()
        NSColor.systemTeal.setStroke(); triangle.lineWidth = 3; triangle.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.darkGray]
        ("3" as NSString).draw(at: CGPoint(x: p.x - 26, y: p.y + 80), withAttributes: attributes)
        ("4" as NSString).draw(at: CGPoint(x: p.x + 112, y: p.y - 30), withAttributes: attributes)
        ("?" as NSString).draw(at: CGPoint(x: p.x + 128, y: p.y + 98), withAttributes: attributes)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
