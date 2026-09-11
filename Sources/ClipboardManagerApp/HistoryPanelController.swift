import AppKit
import ClipboardManagerCore

@MainActor
final class HistoryPanelController: NSObject {
    private let store: ClipboardStore
    private var panel: NSPanel?
    private var stack: NSStackView?

    init(store: ClipboardStore) {
        self.store = store
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        let panel = makePanelIfNeeded()
        rebuild()
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.visibleFrame, false) } ?? NSScreen.main
        let size = panel.frame.size
        var origin = NSPoint(x: cursor.x + 12, y: cursor.y - size.height - 12)
        if let screen {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        panel.contentView = scroll
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        self.panel = panel
        self.stack = stack
        return panel
    }

    private func rebuild() {
        guard let stack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let records = store.list()
        if records.isEmpty {
            let empty = NSTextField(labelWithString: "还没有剪贴板历史")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        for record in records.prefix(100) {
            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(selectItem(_:))
            button.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
            switch record.payload {
            case .text(let value):
                button.title = value.replacingOccurrences(of: "\n", with: " ").prefix(160).description
                button.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            case .image(let data):
                button.title = "图片 · \(data.count / 1024) KB"
                button.image = NSImage(data: data)
                button.image?.size = NSSize(width: 56, height: 56)
                button.heightAnchor.constraint(equalToConstant: 64).isActive = true
            }
            stack.addArrangedSubview(button)
        }
    }

    @objc private func selectItem(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value),
              let record = store.list().first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch record.payload {
        case .text(let text): pasteboard.setString(text, forType: .string)
        case .image(let data): pasteboard.setData(data, forType: .png)
        }
        panel?.orderOut(nil)
    }
}
