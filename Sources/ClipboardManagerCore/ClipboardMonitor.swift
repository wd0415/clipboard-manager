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

    public static func payload(from raw: RawClipboard) -> ClipPayload {
        switch raw {
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
