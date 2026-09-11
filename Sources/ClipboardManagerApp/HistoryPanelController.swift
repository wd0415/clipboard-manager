import AppKit
import ClipboardManagerCore

/// Presents the clipboard history as a native `NSMenu`.
///
/// Using a menu rather than a custom window is what buys the translucent material, rounded
/// corners, row highlight and arrow-key navigation — none of which are reimplemented here.
///
/// `NSMenu` sizes itself to its widest and tallest content and exposes no maximum for either
/// (`minimumWidth` is a floor, not a ceiling). The bounds below are therefore enforced by sizing
/// the row views and by handing the menu no more rows than fit — never by setting a size on the
/// menu. Both constants are measured, not estimated: a row view 260pt wide renders a 260pt menu
/// with no added chrome, and a menu spends ~12pt vertically on padding.
@MainActor
final class HistoryPanelController: NSObject, NSMenuDelegate {
    /// How the history is laid out. The two entry points want different things: the ⌘⇧V pop-up
    /// must stay under the height cap, while "显示历史" in the status menu is expected to hold
    /// the whole history and scroll.
    enum Mode {
        case paged
        case scrolling
    }

    /// Widest the menu may render.
    private let maxMenuWidth: CGFloat = 260
    /// Tallest the menu may render.
    private let maxMenuHeight: CGFloat = 300
    /// Vertical space the menu spends on padding, measured from a rendered menu.
    private let menuChromeHeight: CGFloat = 12
    /// Entries per page. Twelve rows fit the height cap; one of them is the paging footer.
    private let recordsPerPage = 11
    /// Ceiling on pages, so a long history cannot turn the pop-up into an endless pager. Entries
    /// past the last page stay reachable through `Mode.scrolling`.
    private let maxPages = 3
    /// Ceiling on how much of a clip is measured before truncation. Clipboard content can be
    /// megabytes, and `truncated` copies the text into an array of characters.
    private let maxMeasuredCharacters = 400

    private let store: ClipboardStore
    private var records: [ClipRecord] = []
    private var pendingSelection: ClipRecord?
    private var mode: Mode = .paged
    private var page = 0
    private var activeMenu: NSMenu?

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
    func show(_ mode: Mode = .paged) -> ClipRecord? {
        self.mode = mode
        pendingSelection = nil
        page = 0
        records = store.list()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        activeMenu = menu
        rebuild(menu)
        // Letting the menu position itself on its first row is also what selects it, which gives
        // arrow-key navigation a starting point.
        _ = menu.popUp(positioning: menu.items.first, at: NSEvent.mouseLocation, in: nil)
        activeMenu = nil
        return pendingSelection
    }

    private var pageCount: Int {
        min(maxPages, max(1, (records.count + recordsPerPage - 1) / recordsPerPage))
    }

    /// Clamped, because deleting entries can leave the stored page past the last one.
    private var currentPage: Int {
        min(page, pageCount - 1)
    }

    /// Rebuilds the menu's rows in place.
    ///
    /// Done while the menu is tracking, for both paging and deletion, so the menu does not close
    /// and reopen under the pointer. Verified against a live tracking menu: removing and adding
    /// items leaves it open and it re-lays out its rows correctly.
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        guard !records.isEmpty else {
            let empty = NSMenuItem(title: "还没有剪贴板历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        switch mode {
        case .scrolling:
            for record in records { menu.addItem(makeItem(for: record)) }
        case .paged:
            let start = currentPage * recordsPerPage
            for record in records[start..<min(start + recordsPerPage, records.count)] {
                menu.addItem(makeItem(for: record))
            }
            menu.addItem(makeFooter())
        }
    }

    private func makeItem(for record: ClipRecord) -> NSMenuItem {
        let thumbnail: NSImage?
        if case .image(let data) = record.payload {
            thumbnail = NSImage(data: data)
        } else {
            thumbnail = nil
        }

        let row = HistoryRowView(
            title: title(for: record),
            thumbnail: thumbnail,
            totalWidth: maxMenuWidth
        )
        row.onSelect = { [weak self] in
            guard let self else { return }
            self.pendingSelection = record
            self.activeMenu?.cancelTracking()
        }
        row.onDelete = { [weak self] in self?.delete(record) }

        let item = NSMenuItem(title: title(for: record), action: nil, keyEquivalent: "")
        item.view = row
        item.representedObject = record.id.uuidString
        return item
    }

    private func makeFooter() -> NSMenuItem {
        let footer = HistoryFooterView(page: currentPage + 1, pageCount: pageCount, totalWidth: maxMenuWidth)
        footer.onPrevious = { [weak self] in self?.turnPage(-1) }
        footer.onNext = { [weak self] in self?.turnPage(1) }
        let item = NSMenuItem(title: "翻页", action: nil, keyEquivalent: "")
        item.view = footer
        return item
    }

    private func turnPage(_ delta: Int) {
        let next = currentPage + delta
        guard (0..<pageCount).contains(next), next != currentPage else { return }
        page = next
        if let activeMenu { rebuild(activeMenu) }
    }

    /// Removes one entry and redraws the rows.
    ///
    /// No confirmation: the click on the row's own delete button is the intent, and the blast
    /// radius is a single row.
    private func delete(_ record: ClipRecord) {
        do {
            try store.delete(id: record.id)
        } catch {
            NSLog("Clipboard history delete failed: %@", String(describing: error))
            return
        }
        records.removeAll { $0.id == record.id }
        if let activeMenu { rebuild(activeMenu) }
    }

    private func title(for record: ClipRecord) -> String {
        let raw: String
        let hasThumbnail: Bool
        switch record.payload {
        case .text(let value):
            raw = value.replacingOccurrences(of: "\n", with: " ")
            hasThumbnail = false
        case .image(let data):
            raw = "图片 · \(data.count / 1024) KB"
            hasThumbnail = true
        }
        let budget = HistoryRowView.titleWidth(hasThumbnail: hasThumbnail, totalWidth: maxMenuWidth)
        return truncated(String(raw.prefix(maxMeasuredCharacters)), to: budget)
    }

    /// Shortens `text` with a trailing ellipsis until it renders within `width` points.
    ///
    /// Measured in points rather than characters because menu text is proportional and the
    /// history is mixed Chinese and Latin — a character budget would be wrong for both.
    private func truncated(_ text: String, to width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
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

    /// Drives the delete button's reveal. This fires for the pointer moving over a row *and* for
    /// arrow-key selection, which is the "hovered or selected" behaviour the row needs.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for candidate in menu.items {
            (candidate.view as? HistoryRowView)?.showsDelete = (candidate === item)
        }
    }
}
