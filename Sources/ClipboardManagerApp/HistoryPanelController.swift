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
/// menu. Both constants are measured, not estimated: a row view 282pt wide renders a 282pt menu
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

    /// Widest the menu may render. 282 rather than 260 because the pin button takes 22pt out of
    /// the row: at 260 the title would shrink to 177pt, and at 282 it keeps the 199pt it has
    /// always had, so a board of zero pins truncates exactly as it did before pinning existed.
    private let maxMenuWidth: CGFloat = 282
    /// Tallest the menu may render. 348pt is fourteen 24pt rows, which is what a full pinboard
    /// above a full first page adds up to.
    private let maxMenuHeight: CGFloat = 348
    /// Vertical space the menu spends on padding, measured from a rendered menu.
    private let menuChromeHeight: CGFloat = 12
    /// Rows the height cap buys once the chrome is subtracted. Stated rather than divided at each
    /// use so that raising the cap cannot leave the budget and the per-page count disagreeing.
    private var maxRowsPerPage: Int {
        Int((maxMenuHeight - menuChromeHeight) / HistoryRowView.height)
    }
    /// Ceiling on pages, so a long history cannot turn the pop-up into an endless pager. Entries
    /// past the last page stay reachable through `Mode.scrolling`.
    private let maxPages = 3
    /// Ceiling on how much of a clip is measured before truncation. Clipboard content can be
    /// megabytes, and `truncated` copies the text into an array of characters.
    private let maxMeasuredCharacters = 400

    /// Where the menu hangs relative to the pointer.
    ///
    /// `popUp(positioning:at:in:)` puts the positioning item's **top-left corner** on the point
    /// it is given, so handing it `NSEvent.mouseLocation` leaves the pointer on the first row's
    /// edge — and the menu rounds its origin to the pixel grid, which lands the pointer in the
    /// padding strip just above the row. Measured against a live menu that is where the `row0` /
    /// `nil` pair of highlights comes from. Half a row down and a margin in from the left puts the
    /// pointer inside the row the cursor starts on, so the pointer and the marked row agree from
    /// the first frame instead of disagreeing until the pointer happens to move.
    private let popUpAnchorOffset = NSPoint(x: -20, y: -HistoryRowView.height / 2)

    /// The bare keys the menu acts on, all of them read by `HotkeyTap` ahead of the menu — see
    /// `handleKey(_:)` for why nothing inside the menu can see them.
    static let previousPageKeyCode: UInt16 = 123
    static let nextPageKeyCode: UInt16 = 124
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76

    private let store: ClipboardStore
    /// The two sections, refreshed together from a single `list()` call so they can never disagree
    /// about what the history holds.
    private var pinnedRecords: [ClipRecord] = []
    private var recentRecords: [ClipRecord] = []
    private var pendingSelection: ClipRecord?
    private var mode: Mode = .paged
    private var page = 0
    private var activeMenu: NSMenu?
    /// Which row of the current page carries the highlight.
    ///
    /// Held here rather than read back from the menu, because the two are not the same thing: the
    /// menu reports `highlightedItem` as `nil` at exactly the moments this needs it — at open,
    /// where it highlights the first row and then reports `nil` for it, and just after a rebuild,
    /// where every item has been replaced. `NSMenu.highlightedItem` is read-only, so a row could
    /// not be marked from that side even if it were reliable.
    private var highlightedRow = 0

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Re-reads the whole history and splits it into the two sections the menu draws.
    private func loadRecords() {
        let stored = store.list()
        pinnedRecords = stored.filter(\.isPinned)
        recentRecords = stored.filter { !$0.isPinned }
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
        highlightedRow = 0
        loadRecords()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        activeMenu = menu
        rebuild(menu)
        // Letting the menu position itself on its first row is also what selects it, which gives
        // arrow-key navigation a starting point — as long as the pointer really lands on that row,
        // which is what `popUpAnchorOffset` is for.
        let mouse = NSEvent.mouseLocation
        let anchor = NSPoint(x: mouse.x + popUpAnchorOffset.x, y: mouse.y + popUpAnchorOffset.y)
        _ = menu.popUp(positioning: menu.items.first, at: anchor, in: nil)
        activeMenu = nil
        return pendingSelection
    }

    private var pageCount: Int {
        min(maxPages, max(1, (recentRecords.count + recordsPerPage - 1) / recordsPerPage))
    }

    /// Clamped, because deleting entries can leave the stored page past the last one.
    private var currentPage: Int {
        min(page, pageCount - 1)
    }

    /// How many recent rows a page carries.
    ///
    /// The pinboard is drawn above them on page one and is not repeated on later pages, so the
    /// budget it costs is paid once. Up to two pins the recent rows still fit and the menu simply
    /// grows; from the third they have to give. `min(11, …)` is what makes a board of zero pins
    /// byte-identical to the menu that shipped before pinning — without it, raising the cap to
    /// fourteen rows would silently hand every user two extra entries per page.
    private var recordsPerPage: Int {
        guard mode == .paged else { return max(1, recentRecords.count) }
        return max(1, min(11, maxRowsPerPage - 1 - pinnedRecords.count))
    }

    /// Where the menu's first recent row sits in the whole history.
    ///
    /// This is what the rows are numbered from, and it is deliberately not 1 on every page: the
    /// ordinal is the entry's position in the history, so page 2 starts at 12. A per-page number
    /// would tell the user nothing they cannot already see by counting rows.
    private var visibleStart: Int {
        mode == .scrolling ? 0 : currentPage * recordsPerPage
    }

    /// The pinboard, which belongs to the first page only — from page two on, the menu is the
    /// recent sequence and nothing else.
    private var visiblePinned: [ClipRecord] {
        mode == .paged && currentPage == 0 ? pinnedRecords : []
    }

    private var visibleRecentEntries: [ClipRecord] {
        let start = visibleStart
        guard start < recentRecords.count else { return [] }
        let end = mode == .scrolling ? recentRecords.count : min(start + recordsPerPage, recentRecords.count)
        return Array(recentRecords[start..<end])
    }

    /// The records the current mode actually puts in the menu, in the order it puts them there,
    /// pinned first.
    ///
    /// This is the single list the menu's rows and `highlightedRow` are both derived from, so that
    /// is what makes "commit the highlighted row" and "draw the highlighted row" agree.
    private var visibleRecords: [ClipRecord] {
        visiblePinned + visibleRecentEntries
    }

    /// Width of the ordinal column, measured against the longest ordinal the menu can show rather
    /// than the one this page happens to end on, so the column does not resize when the page turns.
    /// Measured against the recent count, because a pinned row carries no number.
    private var ordinalWidth: CGFloat {
        HistoryRowView.ordinalWidth(forLargest: max(recentRecords.count, 1))
    }

    /// Rebuilds the menu's rows in place.
    ///
    /// Done while the menu is tracking, for both paging and deletion, so the menu does not close
    /// and reopen under the pointer. Verified against a live tracking menu: removing and adding
    /// items leaves it open and it re-lays out its rows correctly.
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        guard !pinnedRecords.isEmpty || !recentRecords.isEmpty else {
            let empty = NSMenuItem(title: "还没有剪贴板历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            // Says what fills the list and when — an empty menu on its own reads as a broken
            // feature rather than one that has not been used yet.
            let guidance = NSMenuItem(title: "复制任意文本或图片后会自动出现在这里", action: nil, keyEquivalent: "")
            guidance.isEnabled = false
            guidance.attributedTitle = NSAttributedString(
                string: guidance.title,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            menu.addItem(guidance)
            return
        }

        // Both modes put the same two sections in the menu; only the footer is paged-only. Which
        // records those are is `visibleRecords`' decision, and it is the same list
        // `highlightedRow` indexes.
        let pinned = visiblePinned
        for (offset, record) in visibleRecords.enumerated() {
            menu.addItem(makeItem(
                for: record,
                ordinal: ordinal(for: record, at: offset),
                // The hairline rides the first recent row rather than the last pinned one, so a
                // pinboard with nothing recent under it draws no line without needing a case.
                drawsDivider: offset == pinned.count && !pinned.isEmpty
            ))
        }
        if mode == .paged { menu.addItem(makeFooter()) }

        // Rebuilding replaces every item, so the menu is left with nothing marked — and the rows
        // draw their own selection, so nothing would show unless it is put back. Deletion keeps
        // the cursor where it was, which lands it on the row that took the deleted one's place.
        let rowCount = menu.items.filter { $0.view is HistoryRowView }.count
        guard rowCount > 0 else { return }
        highlightedRow = min(highlightedRow, rowCount - 1)
        applyHighlight(in: menu)
    }

    /// Marks the row `highlightedRow` as selected and every other row as not. The rows draw their
    /// own selection, so this is the only thing that puts a highlight on screen.
    private func applyHighlight(in menu: NSMenu) {
        var row = 0
        for item in menu.items {
            guard let view = item.view as? HistoryRowView else { continue }
            view.isHighlighted = (row == highlightedRow)
            row += 1
        }
    }

    /// Acts on a bare key while the menu is up, and answers whether it was consumed.
    ///
    /// These keys have to be caught before the menu sees them. While a menu is tracking it runs
    /// its own Carbon event loop over navigation keys, and nothing inside the application gets a
    /// look at them: measured against a live menu, a hidden item's key equivalent never fires,
    /// `NSMenu.performKeyEquivalent(with:)` is never called, and a local event monitor never
    /// receives the event. `HotkeyTap`, which sits ahead of the menu at the session level, is the
    /// only place left — so the keys arrive here instead.
    ///
    /// Return is here for the same reason the arrows are, and it is the keyboard's way to pick an
    /// entry: without it the only way to choose one is the pointer. It commits the row that is
    /// marked, which is exactly what a click on that row does.
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard activeMenu != nil else { return false }
        switch keyCode {
        case Self.previousPageKeyCode, Self.nextPageKeyCode:
            // Paging is a paged-mode idea; the scrolling menu already shows everything at once.
            guard mode == .paged else { return false }
            turnPage(keyCode == Self.nextPageKeyCode ? 1 : -1)
            return true
        case Self.returnKeyCode, Self.keypadEnterKeyCode:
            return commitHighlightedRow()
        default:
            return false
        }
    }

    /// Picks the marked entry and closes the menu, the same two steps `mouseDown` takes.
    ///
    /// Closing is `cancelTracking` rather than letting the menu pick the item itself: the item
    /// carries no action, because a view-based row is not selected by the menu — the same reason
    /// `HistoryRowView.draw` has to paint the selection.
    private func commitHighlightedRow() -> Bool {
        let visible = visibleRecords
        guard visible.indices.contains(highlightedRow) else { return false }
        pendingSelection = visible[highlightedRow]
        activeMenu?.cancelTracking()
        return true
    }

    /// The row's number in the recent sequence. A pinned entry has none: the number is a position
    /// among the recent entries, and pinning is precisely having left that sequence.
    private func ordinal(for record: ClipRecord, at offset: Int) -> Int? {
        guard !record.isPinned else { return nil }
        return visibleStart + (offset - visiblePinned.count) + 1
    }

    private func makeItem(for record: ClipRecord, ordinal: Int?, drawsDivider: Bool) -> NSMenuItem {
        let thumbnail: NSImage?
        if case .image(let data) = record.payload {
            thumbnail = NSImage(data: data)
        } else {
            thumbnail = nil
        }

        let row = HistoryRowView(
            title: title(for: record, ordinal: ordinal),
            thumbnail: thumbnail,
            ordinal: ordinal,
            isPinned: record.isPinned,
            ordinalWidth: ordinalWidth,
            totalWidth: maxMenuWidth
        )
        row.drawsDivider = drawsDivider
        row.onSelect = { [weak self] in
            guard let self else { return }
            self.pendingSelection = record
            self.activeMenu?.cancelTracking()
        }
        row.onDelete = { [weak self] in self?.delete(record) }
        row.onTogglePin = { [weak self] in self?.togglePin(record) }

        let item = NSMenuItem(title: title(for: record, ordinal: ordinal), action: nil, keyEquivalent: "")
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
        // A new page starts with the cursor at its top, not at whatever row held it before.
        highlightedRow = 0
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
        loadRecords()
        if let activeMenu { rebuild(activeMenu) }
    }

    /// Pins or unpins an entry, then redraws.
    ///
    /// A full pinboard is answered by the row flashing its own pin button red. Not an alert, and
    /// not dropping the oldest pinned entry to make room: which entry gives up its place is the
    /// user's decision, not a side effect of this click.
    private func togglePin(_ record: ClipRecord) {
        let outcome: PinOutcome
        do {
            outcome = try store.setPinned(!record.isPinned, id: record.id)
        } catch {
            // An I/O failure leaves the menu exactly as it was, which is also the state a user who
            // saw nothing happen can retry from.
            NSLog("Clipboard history pin failed: %@", String(describing: error))
            return
        }
        if outcome == .refusedBoardIsFull {
            rowView(for: record.id, in: activeMenu)?.refusePin()
            return
        }
        loadRecords()
        if let activeMenu { rebuild(activeMenu) }
    }

    /// Finds a row by the id `makeItem` tagged it with.
    ///
    /// `representedObject` is the right source here even though it is the wrong one for the
    /// highlight: this is an identity written here and read back unchanged, with no second copy
    /// of it for the menu to report instead.
    private func rowView(for id: UUID, in menu: NSMenu?) -> HistoryRowView? {
        menu?.items.first { $0.representedObject as? String == id.uuidString }?.view as? HistoryRowView
    }

    private func title(for record: ClipRecord, ordinal: Int?) -> String {
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
        let budget = HistoryRowView.titleWidth(
            hasThumbnail: hasThumbnail,
            showsOrdinal: ordinal != nil,
            ordinalWidth: ordinalWidth,
            totalWidth: maxMenuWidth
        )
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

    /// Moves the highlight to the row the menu reports. This fires for the pointer moving over a
    /// row *and* for arrow-key selection, which is the "hovered or selected" behaviour the row
    /// needs.
    ///
    /// `nil` is ignored rather than taken as "nothing is highlighted". The menu reports it for the
    /// row it has just highlighted — opening sends `willHighlight: row0` and then
    /// `willHighlight: nil`, which is the highlight the user never saw — and again whenever the
    /// pointer leaves the rows. Keeping the last row marked leaves the delete button and the arrow
    /// keys something to sit on.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let item else { return }
        var row = 0
        for candidate in menu.items {
            guard candidate.view is HistoryRowView else { continue }
            if candidate === item {
                highlightedRow = row
                applyHighlight(in: menu)
                return
            }
            row += 1
        }
    }
}
