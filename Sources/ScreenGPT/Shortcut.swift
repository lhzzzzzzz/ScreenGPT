import AppKit
import Carbon
import SwiftUI

@MainActor final class GlobalShortcut {
    private var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private var key: (UInt32, UInt32)?
    var action: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context -> OSStatus in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(code: UInt32, modifiers: UInt32) throws {
        if let key, key.0 == code && key.1 == modifiers { return }
        var next: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x53475054, id: 1), GetApplicationEventTarget(), 0, &next)
        guard status == noErr else { throw AppFailure("这个快捷键已被占用，请选择其他组合。") }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next; key = (code, modifiers)
    }
    deinit { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) } }
}

struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let commit: (UInt32, UInt32, String) -> Void
    func makeNSView(context: Context) -> RecorderView { let v = RecorderView(); v.commit = commit; v.label = label; v.setAccessibilityElement(true); return v }
    func updateNSView(_ view: RecorderView, context: Context) { view.label = label; view.commit = commit; view.needsDisplay = true }
}
final class RecorderView: NSView {
    var label = ""
    var recording = false
    var commit: ((UInt32, UInt32, String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { recording = true; window?.makeFirstResponder(self); needsDisplay = true }
    override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).stroke()
        let text = recording ? "按下组合键…" : label
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; needsDisplay = true; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option), let character = event.charactersIgnoringModifiers?.uppercased(), !character.isEmpty else { NSSound.beep(); return }
        var mods: UInt32 = 0, description = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); description += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); description += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); description += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); description += "⌘" }
        let special: [UInt16: String] = [49: "空格", 36: "↩", 48: "⇥", 51: "⌫"]
        description += special[event.keyCode] ?? character
        commit?(UInt32(event.keyCode), mods, description)
        recording = false; needsDisplay = true
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "全局快捷键，当前 " + label }
    override func accessibilityPerformPress() -> Bool { recording = true; window?.makeFirstResponder(self); needsDisplay = true; return true }
}
