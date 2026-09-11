import AppKit
import ClipboardManagerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: MacClipboardMonitor?
    private var store: ClipboardStore?
    private var historyPanel: HistoryPanelController?
    private var settingsController: SettingsController?
    private var globalMonitor: Any?
    private var shortcut = ShortcutBinding.default
    private var didInitialize = false

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
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardManager", isDirectory: true)
        NSLog("Clipboard Manager data path: %@", applicationSupport.path)
        do {
            let store = try ClipboardStore(directory: applicationSupport)
            self.store = store
            NSLog("Clipboard Manager local store ready")
            self.historyPanel = HistoryPanelController(store: store)
            self.settingsController = SettingsController(store: store, getShortcut: { [weak self] in self?.shortcut ?? .default }, saveShortcut: { [weak self] value in self?.shortcut = value; self?.persistShortcut(value) })
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
        statusItem.button?.title = "📋"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Clipboard Manager 已运行", action: nil, keyEquivalent: ""))
        let showItem = NSMenuItem(title: "显示历史  \(shortcut.displayName)", action: #selector(showHistory), keyEquivalent: "v")
        showItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(showItem)
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.shortcut.matches(event) == true else { return }
            Task { @MainActor in self?.historyPanel?.toggle() }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showHistory() {
        historyPanel?.toggle()
    }

    @objc private func showSettings() { settingsController?.show() }

    private func loadShortcut() -> ShortcutBinding {
        guard let data = UserDefaults.standard.data(forKey: "historyShortcut"), let value = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else { return .default }
        return value
    }

    private func persistShortcut(_ value: ShortcutBinding) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "historyShortcut") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.finishLaunching()
delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
application.run()
