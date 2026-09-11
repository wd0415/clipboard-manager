import AppKit
import Foundation
import Testing
@testable import ClipboardManagerCore

/// A private pasteboard per test, so parallel tests cannot see each other's writes.
private func makeMonitor(_ onClip: @escaping (ClipPayload) -> Void) -> (MacClipboardMonitor, NSPasteboard) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipboardManagerTest-\(UUID().uuidString)"))
    return (MacClipboardMonitor(pasteboard: pasteboard, onClip: onClip), pasteboard)
}

private func copy(_ value: String, to pasteboard: NSPasteboard, then monitor: MacClipboardMonitor) {
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
    monitor.pollNow()
}

@Test func normalizerRemovesImmediateDuplicates() {
    let normalizer = ClipNormalizer()

    #expect(normalizer.accept(.text("same")))
    #expect(!normalizer.accept(.text("same")))
    #expect(normalizer.accept(.text("different")))
}

@Test func rawImageAndTextBecomePayloads() {
    #expect(ClipNormalizer.payload(from: .text("hello")) == .text("hello"))
    #expect(ClipNormalizer.payload(from: .image(Data([1, 2]))) == .image(Data([1, 2])))
}

@Test func rawAndPayloadRoundTrip() {
    #expect(ClipNormalizer.raw(from: .text("hello")) == .text("hello"))
    #expect(ClipNormalizer.raw(from: .image(Data([1, 2]))) == .image(Data([1, 2])))
}

/// The failure `markHandled` exists to prevent. Reusing an entry writes it back to the
/// pasteboard, and because the normalizer only remembers the most recent value, the monitor
/// stores a second copy of content it already holds.
@MainActor
@Test func recopyingWithoutMarkingItCapturesADuplicate() {
    var captured: [ClipPayload] = []
    let (monitor, pasteboard) = makeMonitor { captured.append($0) }

    copy("reused", to: pasteboard, then: monitor)
    copy("other", to: pasteboard, then: monitor)
    copy("reused", to: pasteboard, then: monitor)

    #expect(captured == [.text("reused"), .text("other"), .text("reused")])
}

@MainActor
@Test func markHandledSuppressesRecaptureOfAReusedEntry() {
    var captured: [ClipPayload] = []
    let (monitor, pasteboard) = makeMonitor { captured.append($0) }

    copy("reused", to: pasteboard, then: monitor)
    copy("other", to: pasteboard, then: monitor)

    // Reusing the older entry: mark it handled before the pasteboard write can be polled.
    monitor.markHandled(.text("reused"))
    copy("reused", to: pasteboard, then: monitor)

    #expect(captured == [.text("reused"), .text("other")])
}

/// Why `clearHistory` resets dedup alongside the store: the pasteboard still holds the last
/// copied value, so without the reset the very next copy of it would be dropped as unchanged and
/// the app would look broken right after being emptied.
@MainActor
@Test func resetDeduplicationLetsTheSameValueBeCapturedAgain() {
    var captured: [ClipPayload] = []
    let (monitor, pasteboard) = makeMonitor { captured.append($0) }

    copy("reused", to: pasteboard, then: monitor)
    copy("reused", to: pasteboard, then: monitor)
    #expect(captured == [.text("reused")])

    monitor.resetDeduplication()
    copy("reused", to: pasteboard, then: monitor)

    #expect(captured == [.text("reused"), .text("reused")])
}
