import AppKit
import CoreGraphics

/// Reactivates a target application and sends ⌘V once it is actually frontmost again.
///
/// Posting synthesized keystrokes requires the app to be trusted for Accessibility — the same
/// trust the global shortcut monitor needs, so this adds no new permission requirement.
@MainActor
final class AutoPaster {
    /// True while a synthesized ⌘V is in flight, so the global monitor can ignore our own events.
    private(set) var isPasting = false
    private let keyCodeV: CGKeyCode = 9

    func paste(into application: NSRunningApplication, timeout: TimeInterval = 1.5) {
        guard !isPasting else { return }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        isPasting = true
        application.activate()
        waitUntilFrontmost(application, deadline: Date().addingTimeInterval(timeout))
    }

    /// Activation latency varies with the target app, so poll for frontmost instead of
    /// sleeping a fixed interval: pasting before the target is frontmost sends ⌘V nowhere.
    private func waitUntilFrontmost(_ application: NSRunningApplication, deadline: Date) {
        if application.isActive {
            sendCommandV()
            isPasting = false
            return
        }
        guard Date() < deadline else {
            // Leave the content on the pasteboard rather than failing silently.
            isPasting = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitUntilFrontmost(application, deadline: deadline)
        }
    }

    private func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
