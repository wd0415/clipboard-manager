import AppKit
import ClipboardManagerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: MacClipboardMonitor?
    private var store: ClipboardStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardManager", isDirectory: true)
        do {
            let store = try ClipboardStore(directory: applicationSupport)
            self.store = store
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
