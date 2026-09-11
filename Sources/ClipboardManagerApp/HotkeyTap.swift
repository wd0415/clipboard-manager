import AppKit
import CoreGraphics

/// Claims the global shortcut so no other application ever sees it.
///
/// `NSEvent.addGlobalMonitorForEvents` cannot do this: it is a read-only observer, so the
/// frontmost application receives the keystroke as well and acts on it. A `CGEvent` tap
/// created with `.defaultTap` may drop events, which is what makes the shortcut ours alone.
///
/// Taps need the same Accessibility trust as global monitors, and macOS disables one whose
/// callback is too slow — hence the re-enable in `handle` rather than a one-shot install.
@MainActor
final class HotkeyTap {
    /// Auto-repeat arrives as further `keyDown` events; without a floor the menu would reopen
    /// on every repeat while the keys are held down.
    private let minimumInterval: TimeInterval = 0.3

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcut: ShortcutBinding
    private var onHotkey: (() -> Void)?
    private var lastFire = Date.distantPast

    init(shortcut: ShortcutBinding) {
        self.shortcut = shortcut
    }

    func update(shortcut: ShortcutBinding) {
        self.shortcut = shortcut
    }

    /// Installs the tap. Returns false when it could not be created, which in practice means
    /// this process is not trusted for Accessibility.
    ///
    /// The tap holds an unretained reference to `self` as its refcon, so the caller must keep
    /// this object alive for as long as the tap is installed and call `remove()` on the way out.
    @discardableResult
    func install(onHotkey: @escaping () -> Void) -> Bool {
        guard tap == nil else { return true }
        self.onHotkey = onHotkey
        // Disabled-by-timeout and disabled-by-user-input only arrive if they are in the mask.
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.tapDisabledByTimeout.rawValue
            | CGEventMask(1) << CGEventType.tapDisabledByUserInput.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = runLoopSource
        return true
    }

    func remove() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        onHotkey = nil
    }

    /// Returns true when the event was the shortcut and must not reach any other application.
    ///
    /// Takes the two fields it needs instead of the `CGEvent` itself: `CGEvent` is not
    /// `Sendable`, so handing one to this main-actor method from the tap callback is a
    /// data-race error under strict concurrency. Both `UInt16` and `UInt64` are.
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: UInt64) -> Bool {
        guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown else { return false }
        let modifiers = Self.modifierRawValue(CGEventFlags(rawValue: flags))
        guard shortcut.matches(keyCode: keyCode, modifiers: modifiers) else { return false }

        let now = Date()
        guard now.timeIntervalSince(lastFire) >= minimumInterval else { return true }
        lastFire = now
        onHotkey?()
        return true
    }

    /// Spelled out rather than bit-casting `CGEventFlags` to `NSEvent.ModifierFlags`, so the
    /// match does not quietly depend on the two sets of constants staying numerically equal.
    private static func modifierRawValue(_ flags: CGEventFlags) -> UInt {
        var raw: UInt = 0
        if flags.contains(.maskControl) { raw |= NSEvent.ModifierFlags.control.rawValue }
        if flags.contains(.maskAlternate) { raw |= NSEvent.ModifierFlags.option.rawValue }
        if flags.contains(.maskShift) { raw |= NSEvent.ModifierFlags.shift.rawValue }
        if flags.contains(.maskCommand) { raw |= NSEvent.ModifierFlags.command.rawValue }
        return raw
    }
}

/// A `CGEventTapCallBack` is a C function pointer and therefore cannot capture, so it reaches
/// the instance through the refcon. `assumeIsolated` is sound because the run loop source is
/// added to the main run loop, which is the only place this callback runs.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let swallowed = MainActor.assumeIsolated { tap.handle(type: type, keyCode: keyCode, flags: flags) }
    return swallowed ? nil : Unmanaged.passUnretained(event)
}
