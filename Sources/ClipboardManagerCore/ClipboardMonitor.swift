import Foundation

public enum RawClipboard: Equatable, Sendable {
    case text(String)
    case image(Data)
}

public final class ClipNormalizer: @unchecked Sendable {
    private var last: RawClipboard?

    public init() {}

    public func accept(_ raw: RawClipboard) -> Bool {
        guard raw != last else { return false }
        last = raw
        return true
    }

    /// Forgets the last accepted value. Required whenever the history is emptied: the pasteboard
    /// still holds whatever was copied last, so re-copying that same value would otherwise be
    /// treated as already seen and silently skipped.
    public func reset() {
        last = nil
    }

    public static func payload(from raw: RawClipboard) -> ClipPayload {
        switch raw {
        case .text(let value): return .text(value)
        case .image(let data): return .image(data)
        }
    }

    public static func raw(from payload: ClipPayload) -> RawClipboard {
        switch payload {
        case .text(let value): return .text(value)
        case .image(let data): return .image(data)
        }
    }
}

#if os(macOS)
import AppKit

public final class MacClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let normalizer: ClipNormalizer
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private let onClip: (ClipPayload) -> Void

    public init(
        pasteboard: NSPasteboard = .general,
        normalizer: ClipNormalizer = ClipNormalizer(),
        onClip: @escaping (ClipPayload) -> Void
    ) {
        self.pasteboard = pasteboard
        self.normalizer = normalizer
        self.lastChangeCount = pasteboard.changeCount
        self.onClip = onClip
    }

    public func start(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Performs one immediate read. Useful for deterministic tests and for a first read on launch.
    public func pollNow() {
        poll()
    }

    /// Records `payload` as already seen, so the pasteboard write the caller just made is not
    /// captured as a fresh entry. Without it, reusing an old entry stores a second copy of
    /// content that is already in the history.
    public func markHandled(_ payload: ClipPayload) {
        _ = normalizer.accept(ClipNormalizer.raw(from: payload))
    }

    /// Forgets the last captured value, so the next copy is stored even if it duplicates what is
    /// already on the pasteboard. Call this whenever the history is emptied.
    public func resetDeduplication() {
        normalizer.reset()
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let raw = readRawClipboard(), normalizer.accept(raw) else { return }
        onClip(ClipNormalizer.payload(from: raw))
    }

    private func readRawClipboard() -> RawClipboard? {
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(text) }
        if let data = pasteboard.data(forType: .png) { return .image(data) }
        if let data = pasteboard.data(forType: .tiff) { return .image(data) }
        return nil
    }
}
#endif
