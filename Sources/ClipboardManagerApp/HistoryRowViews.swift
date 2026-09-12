import AppKit

/// One history entry, drawn as a menu row.
///
/// The row leads with the entry's ordinal — its position in the whole history, so a row on the
/// third page still says which entry it is instead of restarting at 1. The ordinal is a position,
/// not a property of the entry: it is not stored, and it is not part of what the row pastes.
///
/// Hosting a custom view in an `NSMenuItem` gives up three behaviours a plain item provides, and
/// all three are restored here on purpose:
///
/// - The menu no longer performs click-to-select for the row, so `mouseDown` selects explicitly.
/// - The delete button cannot be revealed with an `NSTrackingArea`. Measured while a menu is
///   tracking, a tracking area fires only when the pointer crosses into it during a move and
///   misses when the pointer arrives directly, so the reveal would be intermittent.
///   `NSMenuDelegate.menu(_:willHighlight:)` is reliable and fires for arrow-key selection too,
///   which is exactly the "hovered or selected" behaviour asked for.
/// - The row is not painted as selected, so `draw` paints it — see `isHighlighted`.
@MainActor
final class HistoryRowView: NSView {
    static let height: CGFloat = 24
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let deleteSize: CGFloat = 16
    private static let thumbnailSize: CGFloat = 18
    private static let cornerRadius: CGFloat = 4

    private let ordinalField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?

    /// Set by the menu delegate when this row becomes the highlighted one.
    ///
    /// The selection is drawn here rather than left to AppKit. A menu item hosting a custom view
    /// is still tracked — `menu(_:willHighlight:)` fires for it and `NSMenu.highlightedItem`
    /// reports it — but the row is never *painted* as selected: measured against a live menu,
    /// every row of the backing table view reports `isSelected == false`, so the row showed no
    /// selection at all. The delete button's reveal hangs off the same state, which is the
    /// "hovered or selected" behaviour the row wants.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            deleteButton.isHidden = !isHighlighted
            deleteButton.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
            ordinalField.textColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    var deleteButtonFrame: NSRect { deleteButton.frame }

    /// Space left for the title once the ordinal, the thumbnail, the delete button and the
    /// margins are taken. The controller needs this to truncate before handing text over, because
    /// a label clips rather than ellipsizing.
    static func titleWidth(hasThumbnail: Bool, ordinalWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        var leading = padding + ordinalWidth + gap
        if hasThumbnail { leading += thumbnailSize + gap }
        return totalWidth - padding - deleteSize - gap - leading
    }

    /// The ordinal column, which the controller has to measure to reserve it.
    ///
    /// Digits are monospaced and the column is sized for the longest ordinal in the menu, so the
    /// numbers line up and the column does not change width from page to page — the titles would
    /// otherwise shift sideways every time the page turns.
    static let ordinalFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuFont(ofSize: 0).pointSize,
        weight: .regular
    )

    static func ordinalWidth(forLargest ordinal: Int) -> CGFloat {
        ("\(ordinal)" as NSString).size(withAttributes: [.font: ordinalFont]).width.rounded(.up)
    }

    init(title: String, thumbnail: NSImage?, ordinal: Int, ordinalWidth: CGFloat, totalWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: Self.height))

        ordinalField.stringValue = "\(ordinal)"
        ordinalField.font = Self.ordinalFont
        ordinalField.textColor = .secondaryLabelColor
        ordinalField.alignment = .right
        ordinalField.frame = NSRect(
            x: Self.padding,
            y: (Self.height - 16) / 2,
            width: ordinalWidth,
            height: 16
        )
        addSubview(ordinalField)

        var titleOriginX = ordinalField.frame.maxX + Self.gap
        if let thumbnail {
            thumbnailView.image = thumbnail
            thumbnailView.imageScaling = .scaleProportionallyUpOrDown
            thumbnailView.frame = NSRect(
                x: titleOriginX,
                y: (Self.height - Self.thumbnailSize) / 2,
                width: Self.thumbnailSize,
                height: Self.thumbnailSize
            )
            addSubview(thumbnailView)
            titleOriginX = thumbnailView.frame.maxX + Self.gap
        }

        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "删除")
        deleteButton.imagePosition = .imageOnly
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .inline
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.frame = NSRect(
            x: totalWidth - Self.padding - Self.deleteSize,
            y: (Self.height - Self.deleteSize) / 2,
            width: Self.deleteSize,
            height: Self.deleteSize
        )
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        addSubview(deleteButton)

        titleField.stringValue = title
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byClipping
        titleField.frame = NSRect(
            x: titleOriginX,
            y: (Self.height - 16) / 2,
            width: deleteButton.frame.minX - Self.gap - titleOriginX,
            height: 16
        )
        addSubview(titleField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Paints the selection the menu does not paint for a view-based row. Filling the whole
    /// bounds matches what the menu draws behind a plain item, whose row is exactly this wide.
    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    /// A row hosting a custom view is not selected by the menu itself. Clicks that land on the
    /// delete button are delivered to the button and never reach here.
    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

/// The paging footer under a paged history menu.
///
/// It is a menu row like any other, but it deliberately does not override `mouseDown`: clicking
/// the footer's background should do nothing rather than pick an entry.
///
/// It carries the keyboard legend as well as the ‹ › buttons. The buttons are the pointer's way
/// to turn a page and the keys are the keyboard's, and nothing else in the menu says so — a menu
/// has no room for a help line, and these four keys are the whole interaction.
@MainActor
final class HistoryFooterView: NSView {
    static let height: CGFloat = 24
    private static let padding: CGFloat = 8
    private static let buttonSize: CGFloat = 16

    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    init(page: Int, pageCount: Int, totalWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: Self.height))

        configure(previousButton, symbol: "chevron.left", action: #selector(previousTapped))
        configure(nextButton, symbol: "chevron.right", action: #selector(nextTapped))
        previousButton.frame.origin = CGPoint(x: Self.padding, y: (Self.height - Self.buttonSize) / 2)
        nextButton.frame.origin = CGPoint(
            x: totalWidth - Self.padding - Self.buttonSize,
            y: (Self.height - Self.buttonSize) / 2
        )
        addSubview(previousButton)
        addSubview(nextButton)

        // Disabled at the ends rather than hidden, so the footer keeps its shape across pages.
        // The tint is stepped down for the disabled end as well: at the same colour the two
        // chevrons read alike, and the footer has to say which way the history can be turned.
        previousButton.isEnabled = page > 1
        previousButton.contentTintColor = page > 1 ? .secondaryLabelColor : .tertiaryLabelColor
        nextButton.isEnabled = page < pageCount
        nextButton.contentTintColor = page < pageCount ? .secondaryLabelColor : .tertiaryLabelColor

        pageLabel.stringValue = "第 \(page)/\(pageCount) 页 · ← → 翻页 · ↵ 粘贴"
        pageLabel.font = .menuFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center
        pageLabel.frame = NSRect(
            x: previousButton.frame.maxX + 4,
            y: (Self.height - 16) / 2,
            width: nextButton.frame.minX - 4 - previousButton.frame.maxX - 4,
            height: 16
        )
        addSubview(pageLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Marks where the entries end. Drawn here rather than added as a real `NSMenuItem.separator()`
    /// because a separator is its own item with its own height, and the menu's height budget is
    /// full at twelve rows — this costs nothing vertically. Insets match the rows' own padding.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: Self.padding, y: bounds.height - 1, width: bounds.width - Self.padding * 2, height: 1).fill()
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.frame.size = NSSize(width: Self.buttonSize, height: Self.buttonSize)
        button.target = self
        button.action = action
    }

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
}
