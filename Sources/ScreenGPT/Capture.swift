import AppKit
import SwiftUI
import ScreenCaptureKit
import ScreenGPTCore

@MainActor final class CaptureSession: ObservableObject {
    @Published var action: CaptureAction = .translate
    @Published var source: Language
    @Published var target: Language
    @Published var answer = ""
    @Published var working = false
    @Published var error: String?
    @Published var saved = false
    @Published var hasResult = false
    private(set) var image: Data?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var entryID = UUID()
    private var answeredSource: Language?
    private var answeredTarget: Language?
    private let preferences: Preferences
    private let account: ChatGPTAccount
    private let history: HistoryStore
    var reveal: (() -> Void)?
    var close: (() -> Void)?
    var reselect: (() -> Void)?
    var settings: (() -> Void)?
    var move: ((CGSize, Bool) -> Void)?
    var preview = false
    init(preferences: Preferences, account: ChatGPTAccount, history: HistoryStore) {
        self.preferences = preferences; self.account = account; self.history = history
        source = preferences.source; target = preferences.target
    }
    func select(image: Data) { reset(); self.image = image }
    func reset() { cancel(silent: true); image = nil; answer = ""; error = nil; hasResult = false; saved = false; answeredSource = nil; answeredTarget = nil; entryID = UUID() }
    func cancel(silent: Bool = false) {
        requestID = UUID(); task?.cancel(); task = nil; working = false
        if !silent { error = "已停止。你可以重新生成回答。" }
    }
    func run(_ action: CaptureAction) {
        guard let image else { return }
        cancel(silent: true); self.action = action; hasResult = true; saved = false; answer = ""; error = nil; working = true; entryID = UUID()
        reveal?()
        let id = requestID, source = source, target = target
        let configuration = preferences.configuration(for: action)
        answeredSource = source; answeredTarget = target
        if preview {
            working = false
            answer = action == .translate ? "**阅读图形，理解关系**\n\n直角三角形的两条直角边分别为 3 和 4。求斜边的长度。\n\n*界面预览示例，未调用模型。*" : "**答案：5**\n\n根据勾股定理：\n\nc² = 3² + 4² = 9 + 16 = 25\n\nc = √25 = **5**\n\n*界面预览示例，未调用模型。*"
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard account.active?.connected == true else { throw AppFailure("先登录 ChatGPT，即可用套餐额度处理截图。") }
                if account.models.isEmpty { await account.loadModels() }
                try Task.checkCancellation()
                guard requestID == id else { return }
                guard let model = configuration.model.isEmpty ? account.models.first : account.models.first(where: { $0.slug == configuration.model }) else {
                    throw AppFailure("\(action.title)所选的模型当前不可用，请在账号设置中重新选择。")
                }
                let result = try await AIClient(account: account).answer(image: image, action: action, source: source, target: target, model: model, effort: configuration.effort) { [weak self] text in
                    guard let self, self.requestID == id else { return }; self.answer = text
                }
                guard requestID == id else { return }
                answer = result; working = false
                if preferences.automaticallySave { save(source: source, target: target) }
            } catch {
                guard requestID == id else { return }
                working = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func save(source: Language? = nil, target: Language? = nil) {
        guard let image, !working, !answer.isEmpty, error == nil, !preview else { return }
        do {
            try history.save(HistoryEntry(id: entryID, action: action, source: source ?? answeredSource ?? self.source, target: target ?? answeredTarget ?? self.target, answer: answer, image: image)); saved = true
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}

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
        if !preview && !CGPreflightScreenCaptureAccess() { reportError?("请先允许屏幕录制。ScreenGPT 只在你按下快捷键时截图。"); showSettings?(); return }
        capturing = true; let version = UUID(); generation = version
        do {
            let frames: [(CGRect, CGImage)]
            if preview, let screen = NSScreen.main { frames = [(screen.frame, PreviewDocument.image(size: screen.frame.size))] }
            else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let tasks = NSScreen.screens.compactMap { screen -> Task<(CGRect, CGImage), Error>? in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return nil }
                    let frame = screen.frame, scale = screen.backingScaleFactor
                    return Task { @MainActor in
                        let config = SCStreamConfiguration()
                        config.width = Int(frame.width * scale)
                        config.height = Int(frame.height * scale)
                        config.showsCursor = false; config.capturesAudio = false
                        let filter = SCContentFilter(display: display, excludingWindows: [])
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
            guard !frames.isEmpty else { throw AppFailure("没有找到可截取的显示器。") }
            let session = CaptureSession(preferences: preferences, account: account, history: history)
            self.session = session; session.preview = preview
            session.close = { [weak self] in self?.close() }
            session.settings = { [weak self] in self?.close(); self?.showSettings?() }
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
            close(); reportError?("无法截取屏幕：\(error.localizedDescription)"); showSettings?()
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
    var start: CGPoint?
    var onSelect: (() -> Void)?
    private var toolbar: NSHostingView<CaptureToolbar>?
    private var result: NSHostingView<AnswerPanel>?
    private var dragHandle: PanelDragHandle?
    private var resultOrigin: CGPoint?
    private var dragOrigin: CGPoint?
    init(image: CGImage, session: CaptureSession, dim: Double, glass: Bool) {
        self.image = image; self.session = session; self.dim = dim; self.glass = glass
        super.init(frame: .zero)
        setAccessibilityLabel("拖动鼠标框选，按 Escape 退出")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
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
            for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
            }
        } else {
            let text = session.preview ? "界面预览 · 拖动框选 · Esc 退出" : "拖动框选 · Esc 退出"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attrs)
            let pill = CGRect(x: (bounds.width - size.width) / 2 - 22, y: 42, width: size.width + 44, height: 42)
            NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: pill, xRadius: 21, yRadius: 21).fill()
            (text as NSString).draw(at: CGPoint(x: pill.minX + 22, y: pill.minY + 12), withAttributes: attrs)
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        onSelect?(); session.reset(); clearSelection()
        start = clamped(convert(event.locationInWindow, from: nil)); selection = CGRect(origin: start!, size: .zero); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { updateSelection(event) }
    override func mouseUp(with event: NSEvent) {
        updateSelection(event); start = nil
        guard let selection, selection.width >= 12, selection.height >= 12 else { clearSelection(); return }
        let rect = OverlayLayout.cropRect(selection: selection, viewSize: bounds.size, pixelSize: CGSize(width: image.width, height: image.height))
        guard let crop = image.cropping(to: rect), let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else { clearSelection(); return }
        session.select(image: png)
        session.reveal = { [weak self] in self?.showResult() }
        session.reselect = { [weak self] in self?.session.reset(); self?.clearSelection() }
        session.move = { [weak self] offset, finished in self?.moveResult(offset, finished: finished) }
        let toolbar = NSHostingView(rootView: CaptureToolbar(session: session, glass: glass))
        self.toolbar = toolbar; addSubview(toolbar)
        arrange(); needsDisplay = true
    }
    private func updateSelection(_ event: NSEvent) {
        guard let start else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
        needsDisplay = true
    }
    func clearSelection() {
        selection = nil; start = nil; toolbar?.removeFromSuperview(); toolbar = nil
        result?.removeFromSuperview(); result = nil; resultOrigin = nil; dragOrigin = nil; needsDisplay = true
        dragHandle?.removeFromSuperview(); dragHandle = nil
        window?.invalidateCursorRects(for: self)
    }
    private func showResult() {
        if result == nil {
            let host = NSHostingView(rootView: AnswerPanel(session: session, glass: glass)); result = host; addSubview(host)
            let handle = PanelDragHandle(); handle.move = { [weak self] in self?.moveResult($0, finished: $1) }
            dragHandle = handle; addSubview(handle)
        }
        arrange()
    }
    private func arrange() {
        guard let selection else { return }
        let layout = OverlayLayout.arrange(selection: selection, bounds: bounds, resultSize: CGSize(width: 372, height: 436), toolbarSize: CGSize(width: 376, height: 52))
        toolbar?.frame = layout.toolbar
        result?.frame = CGRect(origin: resultOrigin ?? layout.result.origin, size: layout.result.size)
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
