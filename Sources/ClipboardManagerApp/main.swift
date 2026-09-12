import AppKit
@preconcurrency import ApplicationServices
import ClipboardManagerCore

/// `kAXTrustedCheckOptionPrompt` is imported as a mutable global `var` of type
/// `Unmanaged<CFString>`, which Swift 6 strict concurrency rejects from both main-actor and
/// nonisolated contexts (`takeUnretainedValue()` is also unavailable inside `@MainActor`).
/// The value is fixed for the process lifetime, so asserting that here is sound.
private nonisolated(unsafe) let accessibilityPromptOptions: CFDictionary = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
] as CFDictionary

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var showHistoryItem: NSMenuItem?
    private var monitor: MacClipboardMonitor?
    private var store: ClipboardStore?
    private var historyPanel: HistoryPanelController?
    private var settingsController: SettingsController?
    private var hotkeyTap: HotkeyTap?
    private var shortcut = ShortcutBinding.default
    private var didInitialize = false
    private var accessibilityTrusted = false
    private let autoPaster = AutoPaster()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didInitialize else { return }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let anotherInstanceIsRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if anotherInstanceIsRunning {
                NSApplication.shared.terminate(nil)
                return
            }
        }
        didInitialize = true
        shortcut = loadShortcut()
        accessibilityTrusted = requestAccessibilityTrustIfNeeded()
        let hotkeyTap = HotkeyTap(shortcut: shortcut)
        self.hotkeyTap = hotkeyTap
        // Installing the tap is also the honest test of the permission: an untrusted process
        // gets a global monitor that silently delivers nothing, but a tap that refuses to exist.
        accessibilityTrusted = hotkeyTap.install(
            onHotkey: { [weak self] in self?.presentHistory() },
            onUnmodifiedKey: { [weak self] keyCode in self?.historyPanel?.handleKey(keyCode) ?? false }
        )
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardManager", isDirectory: true)
        NSLog("Clipboard Manager data path: %@", applicationSupport.path)
        do {
            let store = try ClipboardStore(directory: applicationSupport)
            self.store = store
            NSLog("Clipboard Manager local store ready")
            self.historyPanel = HistoryPanelController(store: store)
            self.settingsController = SettingsController(store: store, getShortcut: { [weak self] in self?.shortcut ?? .default }, saveShortcut: { [weak self] value in
                self?.shortcut = value
                self?.hotkeyTap?.update(shortcut: value)
                self?.persistShortcut(value)
                self?.applyShortcutToStatusMenu()
            })
            let monitor = MacClipboardMonitor { [weak self] payload in
                do { _ = try self?.store?.insert(payload) }
                catch { NSLog("Clipboard history write failed: %@", String(describing: error)) }
            }
            monitor.start()
            self.monitor = monitor
        } catch {
            NSLog("Clipboard Manager failed to start: %@", String(describing: error))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A template symbol rather than an emoji: it takes its colour and optical weight from the
        // menu bar and sits with the items around it, which a colour emoji at its own size does not.
        let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard Manager")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Clipboard Manager 已运行", action: nil, keyEquivalent: ""))
        if !accessibilityTrusted {
            let warning = NSMenuItem(
                title: "⚠️ 需授予辅助功能权限，\(shortcut.displayName) 才生效",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let showItem = NSMenuItem(title: "", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(showItem)
        showHistoryItem = showItem
        applyShortcutToStatusMenu()
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "清空历史", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        NSLog("Clipboard Manager accessibility trusted: %d", accessibilityTrusted ? 1 : 0)
    }

    /// Global key monitoring delivers nothing to an untrusted process, and macOS reports no
    /// error when that happens. Ask for the grant explicitly, and let the caller surface the
    /// state, so a missing permission shows up instead of silently disabling the shortcut.
    private func requestAccessibilityTrustIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        _ = AXIsProcessTrustedWithOptions(accessibilityPromptOptions)
        return AXIsProcessTrusted()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// "显示历史" shows the whole history in one scrolling menu, unlike the ⌘⇧V pop-up, which is
    /// paged to stay under its height cap.
    @objc private func showHistory() {
        presentHistory(mode: .scrolling)
    }

    /// Shows the history menu, then writes the chosen entry to the pasteboard and pastes it
    /// back into whichever app was frontmost when the shortcut fired. The target app is
    /// captured before the menu opens, because showing the menu changes the frontmost app.
    private func presentHistory(mode: HistoryPanelController.Mode = .paged) {
        guard !autoPaster.isPasting else { return }
        let target = NSWorkspace.shared.frontmostApplication
        guard let record = historyPanel?.show(mode) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch record.payload {
        case .text(let text): pasteboard.setString(text, forType: .string)
        case .image(let data): pasteboard.setData(data, forType: .png)
        }
        // Reusing an entry promotes the row that already holds it rather than adding a second
        // copy. `markHandled` must follow the write before the monitor's next poll; both run on
        // the main actor, so nothing can interleave between them.
        try? store?.promote(id: record.id)
        monitor?.markHandled(record.payload)
        if let target { autoPaster.paste(into: target) }
    }

    @objc private func showSettings() { settingsController?.show() }

    /// Empties the history, after asking.
    ///
    /// "取消" is added first on purpose: `NSAlert` makes the first button the default, and having
    /// Return trigger the destructive choice would make a stray keypress wipe everything.
    ///
    /// The dedup memory is reset alongside the store, because the pasteboard still holds the last
    /// copied value — without the reset, re-copying it right after a clear would be dropped as
    /// already seen and the app would look broken.
    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "所有已保存的记录都会被删除，此操作无法撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store?.clear()
            monitor?.resetDeduplication()
        } catch {
            NSLog("Clipboard history clear failed: %@", String(describing: error))
        }
    }

    private func loadShortcut() -> ShortcutBinding {
        guard let data = UserDefaults.standard.data(forKey: "historyShortcut"), let value = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else { return .default }
        return value
    }

    /// Keeps the status menu's "显示历史" row in step with the binding.
    ///
    /// The row names the keys and also carries them as its key equivalent, so a rebind has to
    /// rewrite both. Rebuilding only the menu's title would still leave it answering to the old
    /// combination — the row would be wrong in what it says and in what it does.
    private func applyShortcutToStatusMenu() {
        guard let showHistoryItem else { return }
        showHistoryItem.title = "显示历史  \(shortcut.displayName)"
        showHistoryItem.keyEquivalent = shortcut.keyEquivalent
        showHistoryItem.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    private func persistShortcut(_ value: ShortcutBinding) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "historyShortcut") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotkeyTap?.remove()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.finishLaunching()
delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
application.run()
