import AppKit
import SwiftUI
import Combine

@MainActor final class AppModel: ObservableObject {
    let preferences = Preferences()
    let account = ChatGPTAccount()
    let history = HistoryStore()
    let shortcut = GlobalShortcut()
    lazy var capture = CaptureCoordinator(preferences: preferences, account: account, history: history)
    @Published var screenPermission = false
    @Published var message: String?
    @Published var settingsPage = "general"
    private var settingsWindow: NSWindow?
    private var pendingCapture: Task<Void, Never>?
    private var captureRequest = UUID()
    private var awaitingScreenPermission = false
    private let screenPermissionHelp = "截屏还未开始：请在 macOS 系统设置的「隐私与安全性 → 屏幕录制」中允许 ScreenGPT。若开关已经开启，请完全退出 ScreenGPT 后重新打开，再按快捷键。"
    init() {
        preferences.applyAppearance()
        shortcut.action = { [weak self] in self?.beginCapture() }
        do { try shortcut.register(code: preferences.shortcutCode, modifiers: preferences.shortcutModifiers) }
        catch { message = error.localizedDescription }
        capture.showSettings = { [weak self] in self?.showSettings(page: "general") }
        capture.reportError = { [weak self] in self?.message = $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancelCapture() } }
    }
    func showSettings(page: String? = nil) {
        if let page { settingsPage = page }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ScreenGPT"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 840, height: 680)
            window.contentView = NSHostingView(rootView: SettingsView(app: self, preferences: preferences, account: account, history: history))
            window.center(); settingsWindow = window
        }
        refreshPermission(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func beginCapture(preview: Bool = false) {
        if pendingCapture != nil || capture.isActive { cancelCapture(); return }
        refreshPermission()
        if !preview && !screenPermission {
            awaitingScreenPermission = true; message = screenPermissionHelp
            showSettings(page: "general")
            return
        }
        message = nil
        settingsWindow?.orderOut(nil)
        let request = UUID(); captureRequest = request
        pendingCapture = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                guard let self, self.captureRequest == request else { return }
                await self.capture.capture(preview: preview)
                if self.captureRequest == request { self.pendingCapture = nil }
            } catch {
                if self?.captureRequest == request { self?.pendingCapture = nil }
            }
        }
    }
    func cancelCapture() {
        captureRequest = UUID(); pendingCapture?.cancel(); pendingCapture = nil; capture.close()
    }
    func refreshPermission() {
        screenPermission = CGPreflightScreenCaptureAccess()
        if screenPermission && awaitingScreenPermission { awaitingScreenPermission = false; message = nil }
    }
    func requestPermission() {
        awaitingScreenPermission = true
        _ = CGRequestScreenCaptureAccess()
        refreshPermission()
        if !screenPermission {
            message = screenPermissionHelp
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    func setShortcut(code: UInt32, modifiers: UInt32, label: String) {
        do {
            try shortcut.register(code: code, modifiers: modifiers)
            preferences.shortcutCode = code; preferences.shortcutModifiers = modifiers; preferences.shortcutLabel = label; message = nil
        } catch { message = error.localizedDescription }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ScreenGPT")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        add("框选屏幕", action: #selector(capture), to: menu)
        menu.addItem(.separator())
        add("设置…", action: #selector(settings), key: ",", to: menu)
        add("已保存", action: #selector(history), to: menu)
        menu.addItem(.separator())
        add("退出 ScreenGPT", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
        let mainMenu = NSMenu(), appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        add("关于 ScreenGPT", action: #selector(about), to: appMenu)
        add("设置…", action: #selector(settings), key: ",", to: appMenu)
        appMenu.addItem(.separator()); add("退出 ScreenGPT", action: #selector(quit), key: "q", to: appMenu)
        let edit = NSMenu(title: "编辑"), editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit; mainMenu.addItem(editItem)
        for (name, action, key) in [("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
        NSApp.mainMenu = mainMenu
        model.showSettings()
        if CommandLine.arguments.contains("--preview") { model.beginCapture(preview: true) }
    }
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item) }
    @objc private func capture() { model.beginCapture() }
    @objc private func settings() { model.cancelCapture(); model.showSettings() }
    @objc private func history() { model.cancelCapture(); model.showSettings(page: "history") }
    @objc private func about() { model.cancelCapture(); model.showSettings(page: "about") }
    @objc private func quit() { model.cancelCapture(); model.account.cancelLogin(); NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model.showSettings(); return true }
}

@main struct ScreenGPTMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
