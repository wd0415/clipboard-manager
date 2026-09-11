import AppKit
import ClipboardManagerCore

/// Presents the clipboard history as a native `NSMenu` at the cursor.
///
/// Using a menu rather than a custom window is what buys the translucent material, rounded
/// corners, row highlight and arrow-key navigation — none of which are reimplemented here.
/// The cost is that menu items render images at icon size, so image entries show a small
/// thumbnail rather than a preview.
///
/// `NSMenu` sizes itself to its widest and tallest content and exposes no maximum for either
/// (`minimumWidth` is a floor, not a ceiling). The bounds below are therefore enforced by
/// shortening the titles and by dropping entries, never by setting a size on the menu.
@MainActor
final class HistoryPanelController: NSObject {
    /// Widest the menu may render, margins included.
    private let maxMenuWidth: CGFloat = 260
    /// Tallest the menu may render, margins included.
    private let maxMenuHeight: CGFloat = 300
    /// Horizontal space the menu spends on its left image column and right margin. Measured,
    /// not estimated: a 200pt title budget rendered a 229pt menu, so the chrome is 29pt.
    private let menuHorizontalChrome: CGFloat = 30
    /// One row's height. Image rows are the tall ones, so this is sized for those.
    private let menuRowHeight: CGFloat = 24
    /// Ceiling on how much of a clip is measured before truncation. Clipboard content can be
    /// megabytes, and `truncated` copies the text into an array of characters.
    private let maxMeasuredCharacters = 400

    private let store: ClipboardStore
    private let titleFont = NSFont.menuFont(ofSize: 0)
    private var pendingSelection: ClipRecord?
    private var recordsByID: [String: ClipRecord] = [:]

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Builds the history menu and tracks it until dismissed, returning the chosen entry.
    ///
    /// `popUp` runs a nested event loop, so this returns only after the menu has closed. The
    /// selection is deliberately read afterwards: sending a synthesized ⌘V while the menu is
    /// still tracking would deliver it to the menu instead of the target application.
    ///
    /// The whole record is returned rather than just its payload so the caller can move that
    /// row to the top of the history instead of storing a duplicate of it.
    func show() -> ClipRecord? {
        pendingSelection = nil
        recordsByID = [:]
        let records = store.list()
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard !records.isEmpty else {
            let empty = NSMenuItem(title: "还没有剪贴板历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return nil
        }

        for record in records.prefix(maxVisibleItems) {
            recordsByID[record.id.uuidString] = record
            menu.addItem(makeItem(for: record))
        }
        // Positioning the menu on its first item selects that item when the menu opens, which
        // gives arrow-key navigation a starting point. For the first item this is also where
        // the menu would sit anyway, so it costs no placement offset.
        _ = menu.popUp(positioning: menu.items.first, at: NSEvent.mouseLocation, in: nil)
        return pendingSelection
    }

    /// Entries are dropped rather than scrolled: the menu has no maximum height, so the only
    /// way to hold it under `maxMenuHeight` is to hand it fewer rows.
    private var maxVisibleItems: Int {
        max(1, Int(maxMenuHeight / menuRowHeight))
    }

    private func makeItem(for record: ClipRecord) -> NSMenuItem {
        let item = NSMenuItem(title: title(for: record), action: #selector(selectItem(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.representedObject = record.id.uuidString
        if case .image(let data) = record.payload {
            let thumbnail = NSImage(data: data)
            thumbnail?.size = NSSize(width: 18, height: 18)
            thumbnail?.isTemplate = false
            item.image = thumbnail
        }
        return item
    }

    private func title(for record: ClipRecord) -> String {
        let raw: String
        switch record.payload {
        case .text(let value): raw = value.replacingOccurrences(of: "\n", with: " ")
        case .image(let data): raw = "图片 · \(data.count / 1024) KB"
        }
        return truncated(String(raw.prefix(maxMeasuredCharacters)), to: maxMenuWidth - menuHorizontalChrome)
    }

    /// Shortens `text` with a trailing ellipsis until it renders within `width` points.
    ///
    /// Measured in points rather than characters because menu text is proportional and the
    /// history is mixed Chinese and Latin — a character budget would be wrong for both.
    private func truncated(_ text: String, to width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont]
        func renderedWidth(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: attributes).width
        }
        guard renderedWidth(text) > width else { return text }

        // Binary search on the number of grapheme clusters: truncating by UTF-16 offset would
        // split an emoji or a flag in half.
        let characters = Array(text)
        var fitting = 0
        var tooLong = characters.count
        while fitting < tooLong {
            let middle = (fitting + tooLong + 1) / 2
            if renderedWidth(String(characters[0..<middle]) + "…") <= width {
                fitting = middle
            } else {
                tooLong = middle - 1
            }
        }
        return String(characters[0..<fitting]) + "…"
    }

    @objc private func selectItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let record = recordsByID[id] else { return }
        pendingSelection = record
    }
}
