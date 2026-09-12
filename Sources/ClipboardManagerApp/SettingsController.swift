import AppKit
import Carbon.HIToolbox
import ClipboardManagerCore

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    static let `default` = ShortcutBinding(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)

    /// Keys that carry no character, named the way macOS names them.
    ///
    /// They have to be listed rather than spelled through the layout below, which reports nothing
    /// for them — an arrow key or Return would otherwise come back empty and read as a bare "⌘".
    private static let namedKeys: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        return value + Self.keyName(for: keyCode)
    }

    /// The character a menu matches this key by, or "" when the key has none.
    ///
    /// Lower case where the layout has a choice: `NSMenuItem` matches the character the key
    /// produces *without* Shift, and Shift travels in the modifier mask instead.
    var keyEquivalent: String {
        guard Self.namedKeys[keyCode] == nil else { return "" }
        return Self.layoutCharacter(for: keyCode) ?? ""
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift])
    }

    /// How the key reads to the user: the character this keyboard layout puts on it, or a
    /// macOS key name where it has no character at all.
    ///
    /// Asking the layout is what makes a rebound shortcut legible. The recorder accepts any key,
    /// so a fixed table would have to spell everything outside it "按键" — which is what the
    /// status menu and the settings field would then show.
    static func keyName(for keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] { return named }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "按键"
    }

    /// The unmodified character the current keyboard layout puts on `keyCode`.
    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
        )
    }

    /// The same test against the raw values a `CGEvent` carries, so the hotkey can be matched
    /// inside an event tap without manufacturing an `NSEvent`.
    func matches(keyCode pressedKeyCode: UInt16, modifiers pressedModifiers: UInt) -> Bool {
        pressedKeyCode == keyCode && pressedModifiers == modifiers
    }
}

/// Records a shortcut by capturing the next key combination pressed while it holds focus.
///
/// Deliberately not an editable text field. An editable field hands keystrokes to a field editor,
/// so the field itself never sees them, and it holds focus by default — meaning the user is
/// invited to type a letter rather than press a combination. Being non-editable costs two
/// overrides, because AppKit grants a label-like field neither first-responder status nor focus
/// on a click, and those two overrides are what make it record only while it is recording: an
/// editable field swallows every key equivalent in the window, ⌘Q included.
final class ShortcutRecorderField: NSTextField {
    var onChange: ((ShortcutBinding) -> Void)?
    private(set) var binding: ShortcutBinding

    private static let prompt = "请按下组合键…"

    init(binding: ShortcutBinding) {
        self.binding = binding
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        stringValue = binding.displayName
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBinding(_ value: ShortcutBinding) {
        binding = value
        if !isRecording { stringValue = binding.displayName }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { showRecording(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { showRecording(false) }
        return resigned
    }

    /// Focus has to be asked for explicitly: a non-editable field is not focused by a click.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            // Escape abandons the capture; the binding keeps whatever it already had.
            window?.makeFirstResponder(nil)
        case 48:
            // Tab is how the user leaves the field, not a combination to record. Moved through
            // the valid key view rather than `selectNextKeyView(_:)`, which is a key-window
            // action and does nothing while the window is not key — the field would then keep
            // recording and swallow the next keystroke instead of letting go of it.
            let target = event.modifierFlags.contains(.shift) ? previousValidKeyView : nextValidKeyView
            window?.makeFirstResponder(target)
        default:
            let allowed = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !allowed.isEmpty else {
                NSSound.beep()
                return
            }
            binding = ShortcutBinding(keyCode: event.keyCode, modifiers: allowed.rawValue)
            onChange?(binding)
            // Capture ends with the first complete combination, so the field goes straight back
            // to showing the binding it now holds.
            window?.makeFirstResponder(nil)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }

    private var isRecording: Bool { window?.firstResponder === self }

    private func showRecording(_ recording: Bool) {
        stringValue = recording ? Self.prompt : binding.displayName
        textColor = recording ? .secondaryLabelColor : .labelColor
    }
}

@MainActor
final class SettingsController: NSObject {
    private let store: ClipboardStore
    private let saveShortcut: (ShortcutBinding) -> Void
    private var window: NSWindow?
    private var shortcutField: ShortcutRecorderField?
    private var pendingShortcut: ShortcutBinding

    init(store: ClipboardStore, getShortcut: @escaping () -> ShortcutBinding, saveShortcut: @escaping (ShortcutBinding) -> Void) {
        self.store = store
        self.saveShortcut = saveShortcut
        self.pendingShortcut = getShortcut()
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // Programmatic windows default this to true, which makes `close()` release the window
        // once more than ARC expects and leaves `self.window` dangling. The second `show()` then
        // retains a dead object and crashes, so the extra release has to be turned off.
        window.isReleasedWhenClosed = false
        window.title = "Clipboard Manager 设置"
        window.center()
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let shortcutLabel = NSTextField(labelWithString: "历史面板快捷键")
        let shortcutField = ShortcutRecorderField(binding: pendingShortcut)
        shortcutField.onChange = { [weak self] binding in self?.pendingShortcut = binding }
        self.shortcutField = shortcutField

        // Sits under the field it describes, not under the next setting: as a caption for the
        // wrong control it read as an explanation of the history limit.
        let hint = NSTextField(wrappingLabelWithString: "点击输入框后按下带修饰键的组合键，例如 ⌘⇧V。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.font = .systemFont(ofSize: 11)

        // Informational rather than a control: the limit is fixed, and the label says so instead
        // of offering a choice the store no longer honours.
        let limitLabel = NSTextField(labelWithString: "历史保留数量")
        let limitValue = NSTextField(labelWithString: "最多 \(store.maxEntries) 条，超出后自动删除最早的")
        limitValue.textColor = .secondaryLabelColor
        limitValue.font = .systemFont(ofSize: 11)
        limitValue.alignment = .right

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))

        [shortcutLabel, shortcutField, hint, reset, limitLabel, limitValue, save, cancel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            shortcutLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            shortcutLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            shortcutField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            shortcutField.centerYAnchor.constraint(equalTo: shortcutLabel.centerYAnchor),
            shortcutField.widthAnchor.constraint(equalToConstant: 180),

            hint.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor),
            // 14 rather than 10: the 恢复默认 button is a small control and stands taller than the
            // caption it shares the row with, so the gap has to clear the button, not the text.
            hint.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: reset.leadingAnchor, constant: -12),
            reset.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor),
            reset.centerYAnchor.constraint(equalTo: hint.centerYAnchor),

            // The gap between the two groups is three times the gap within one, which is what
            // groups them — no divider is needed for two settings.
            limitLabel.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor),
            limitLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 28),
            limitValue.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor),
            limitValue.centerYAnchor.constraint(equalTo: limitLabel.centerYAnchor),

            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -12),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            save.bottomAnchor.constraint(equalTo: cancel.bottomAnchor),
        ])
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func save() {
        saveShortcut(pendingShortcut)
        window?.close()
    }

    @objc private func resetShortcut() {
        // Ends any capture in progress first, or the field would keep showing the prompt while
        // the binding behind it had already changed.
        window?.makeFirstResponder(nil)
        pendingShortcut = .default
        shortcutField?.setBinding(.default)
    }

    @objc private func cancel() { window?.close() }
}
