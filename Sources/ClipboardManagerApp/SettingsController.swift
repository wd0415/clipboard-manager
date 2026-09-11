import AppKit
import ClipboardManagerCore

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    static let `default` = ShortcutBinding(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)

    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        let key: String
        switch keyCode {
        case 9: key = "V"
        case 0: key = "A"
        case 1: key = "S"
        case 2: key = "D"
        case 3: key = "F"
        default: key = "按键"
        }
        return value + key
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue == modifiers
    }
}

final class ShortcutRecorderField: NSTextField {
    var onChange: ((ShortcutBinding) -> Void)?

    override func keyDown(with event: NSEvent) {
        let allowed = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !allowed.isEmpty else { NSSound.beep(); return }
        let binding = ShortcutBinding(keyCode: event.keyCode, modifiers: allowed.rawValue)
        stringValue = binding.displayName
        onChange?(binding)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }
}

@MainActor
final class SettingsController: NSObject {
    private let store: ClipboardStore
    private let getShortcut: () -> ShortcutBinding
    private let saveShortcut: (ShortcutBinding) -> Void
    private var window: NSWindow?
    private var shortcutField: ShortcutRecorderField?
    private var limitPopup: NSPopUpButton?
    private var pendingShortcut: ShortcutBinding

    init(store: ClipboardStore, getShortcut: @escaping () -> ShortcutBinding, saveShortcut: @escaping (ShortcutBinding) -> Void) {
        self.store = store
        self.getShortcut = getShortcut
        self.saveShortcut = saveShortcut
        self.pendingShortcut = getShortcut()
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clipboard Manager 设置"
        window.center()
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let shortcutLabel = NSTextField(labelWithString: "历史面板快捷键")
        let shortcutField = ShortcutRecorderField(string: pendingShortcut.displayName)
        shortcutField.placeholderString = "点击后按下组合键"
        shortcutField.alignment = .center
        shortcutField.isEditable = true
        shortcutField.onChange = { [weak self] binding in self?.pendingShortcut = binding }
        self.shortcutField = shortcutField

        let limitLabel = NSTextField(labelWithString: "最大历史数量")
        let popup = NSPopUpButton()
        [100, 500, 1000, 2000, 5000].forEach { popup.addItem(withTitle: "\($0) 条") }
        let currentLimit = store.maxEntries
        popup.selectItem(withTitle: "\(currentLimit) 条")
        if popup.selectedItem == nil { popup.selectItem(at: 1) }
        self.limitPopup = popup

        let hint = NSTextField(labelWithString: "点击快捷键输入框后，按下带修饰键的组合键，例如 ⌘⇧V。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))

        [shortcutLabel, shortcutField, limitLabel, popup, hint, save, cancel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            shortcutLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), shortcutLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            shortcutField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), shortcutField.centerYAnchor.constraint(equalTo: shortcutLabel.centerYAnchor), shortcutField.widthAnchor.constraint(equalToConstant: 180),
            limitLabel.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor), limitLabel.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 30),
            popup.trailingAnchor.constraint(equalTo: shortcutField.trailingAnchor), popup.centerYAnchor.constraint(equalTo: limitLabel.centerYAnchor), popup.widthAnchor.constraint(equalToConstant: 180),
            hint.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor), hint.topAnchor.constraint(equalTo: limitLabel.bottomAnchor, constant: 26),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -12), cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28), save.bottomAnchor.constraint(equalTo: cancel.bottomAnchor)
        ])
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func save() {
        if let limit = Int(limitPopup?.titleOfSelectedItem?.split(separator: " ").first ?? "500") { try? store.setMaxEntries(limit) }
        saveShortcut(pendingShortcut)
        window?.close()
    }

    @objc private func cancel() { window?.close() }
}
