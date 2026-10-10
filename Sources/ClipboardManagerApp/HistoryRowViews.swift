import AppKit

/// One history entry, drawn as a menu row.
///
/// The row leads with the entry's ordinal — its position in the whole history, so a row on the
/// third page still says which entry it is instead of restarting at 1. The ordinal is a position,
/// not a property of the entry: it is not stored, and it is not part of what the row pastes. A
/// pinned row carries none: pinning is precisely having left the sequence the number counts.
///
/// The trailing area holds two buttons. The pin button rides the same reveal as the delete
/// button rather than a tracking area of its own, and a pinned row keeps it on screen at all
/// times because that constant mark is how the row says it is pinned.
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
    private static let pinSize: CGFloat = 16
    private static let thumbnailSize: CGFloat = 18
    private static let cornerRadius: CGFloat = 4

    /// How long the pin button stays red when the pinboard is full: long enough to be seen, short
    /// enough that a red button cannot be mistaken for a state the row is stuck in.
    static let pinRefusalSeconds: TimeInterval = 0.6

    private let ordinalField: NSTextField?
    private let titleField = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    /// Whether this entry is pinned. A pinned row keeps its pin button on screen at all times —
    /// that constant mark is the whole of how the row says it is pinned — and shows it as the
    /// undo glyph, because clicking it is what unpins.
    private let isPinned: Bool

    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    var onTogglePin: (() -> Void)?

    /// Paints the hairline that ends the pinned section.
    ///
    /// Set on the first recent row rather than on the last pinned one, so the boundary needs no
    /// special case: with nothing recent there is no row to carry it and no line is drawn. Drawn
    /// rather than made an `NSMenuItem.separator()`, which is an item with a height of its own,
    /// and the row budget here is exact.
    var drawsDivider = false {
        didSet { needsDisplay = true }
    }

    /// True while the pin button is showing that the pinboard refused this click.
    private var isRefusingPin = false

    var deleteButtonFrame: NSRect { deleteButton.frame }

    /// Space left for the title once the ordinal, the thumbnail, the two trailing buttons and the
    /// margins are taken. The controller truncates to this before handing text over, because a
    /// label clips rather than ellipsizing.
    ///
    /// Both trailing buttons are reserved whether or not they are on screen. A hidden button that
    /// took no room would let the title widen the moment the row was highlighted, which reads as
    /// the text jumping sideways under the pointer.
    ///
    /// At `totalWidth` 282 with a 17pt ordinal column this is 199pt for a recent row and 222pt for
    /// a pinned one. It was 199pt before the pin button existed, which is why the menu is 282
    /// rather than 260: at 260 it would come to 177pt.
    static func titleWidth(hasThumbnail: Bool, showsOrdinal: Bool, ordinalWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        var leading = padding
        if showsOrdinal { leading += ordinalWidth + gap }
        if hasThumbnail { leading += thumbnailSize + gap }
        // padding, pin button, its gap, delete button, and the gap between the delete button and
        // the title — five terms, two of them gaps.
        let trailing = padding + pinSize + gap + deleteSize + gap
        return totalWidth - leading - trailing
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

    /// Set by the menu delegate when this row becomes the highlighted one.
    ///
    /// The selection is drawn here rather than left to AppKit. A menu item hosting a custom view
    /// is still tracked — `menu(_:willHighlight:)` fires for it and `NSMenu.highlightedItem`
    /// reports it — but the row is never *painted* as selected: measured against a live menu,
    /// every row of the backing table view reports `isSelected == false`, so the row showed no
    /// selection at all. The trailing buttons' reveal hangs off the same state, which is the
    /// "hovered or selected" behaviour the row wants.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateAppearance()
        }
    }

    /// The one place that decides what is visible and what colour everything is.
    ///
    /// The pin button has three states — hidden, shown, refusing — and the refusal has to survive
    /// a highlight change landing on top of it, so the two go through this one entry point rather
    /// than each keeping their own idea of what colour everything is.
    private func updateAppearance() {
        pinButton.isHidden = !(isHighlighted || isPinned)
        deleteButton.isHidden = !isHighlighted

        let trailing: NSColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        // A refusal outranks the highlight tint, or it would not read as a refusal at all.
        pinButton.contentTintColor = isRefusingPin ? .systemRed : trailing
        deleteButton.contentTintColor = trailing
        titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        ordinalField?.textColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        needsDisplay = true
    }

    /// Answers a refused pin: the board is full, so this click changed nothing.
    ///
    /// Red for a moment rather than an alert. Pinning is a deliberate, infrequent click, so it
    /// deserves an answer, and the thing being reported — one board of five being full — is
    /// smaller than the window an alert would put on screen to say it.
    func refusePin() {
        isRefusingPin = true
        updateAppearance()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.pinRefusalSeconds * 1000)))
            guard let self, self.isRefusingPin else { return }
            self.isRefusingPin = false
            self.updateAppearance()
        }
    }

    /// `ordinal` is the entry's position in the recent sequence; pass `nil` for a pinned entry,
    /// which has left that sequence and therefore has no position in it.
    init(title: String, thumbnail: NSImage?, ordinal: Int?, isPinned: Bool, ordinalWidth: CGFloat, totalWidth: CGFloat) {
        // Every stored property has to hold a value before `super.init`, and the ordinal column is
        // the awkward one: a pinned row has no position in the recent sequence, so it gets no
        // label. It is built here rather than after `super.init` because that would mean reaching
        // for `self` while a `let` is still uninitialized. Nothing below touches `self`.
        var ordinalLabel: NSTextField?
        var titleOriginX = Self.padding
        if let ordinal {
            let label = NSTextField(labelWithString: "\(ordinal)")
            label.font = Self.ordinalFont
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.frame = NSRect(x: Self.padding, y: (Self.height - 16) / 2, width: ordinalWidth, height: 16)
            ordinalLabel = label
            titleOriginX = label.frame.maxX + Self.gap
        }
        ordinalField = ordinalLabel
        self.isPinned = isPinned
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: Self.height))

        if let ordinalField { addSubview(ordinalField) }

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

        // `pin.slash` is the undo glyph — a pin with a slash through it — and it ships with
        // SF Symbols 4.0, so the macOS 14 deployment target has it. The fallback is there because
        // `NSImage(systemSymbolName:)` answers a symbol it cannot find with nil, and a button with
        // no image is a blank the size of a target rather than an error.
        let pinSymbol = isPinned ? "pin.slash" : "pin"
        let pinFallback = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: pinSymbol, accessibilityDescription: isPinned ? "取消固定" : "固定")
            ?? NSImage(systemSymbolName: pinFallback, accessibilityDescription: nil)
        pinButton.imagePosition = .imageOnly
        pinButton.isBordered = false
        pinButton.bezelStyle = .inline
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.frame = NSRect(
            x: deleteButton.frame.minX - Self.gap - Self.pinSize,
            y: (Self.height - Self.pinSize) / 2,
            width: Self.pinSize,
            height: Self.pinSize
        )
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.isHidden = !isPinned
        addSubview(pinButton)

        titleField.stringValue = title
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byClipping
        titleField.frame = NSRect(
            x: titleOriginX,
            y: (Self.height - 16) / 2,
            width: pinButton.frame.minX - Self.gap - titleOriginX,
            height: 16
        )
        addSubview(titleField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Paints the selection the menu does not paint for a view-based row. Filling the whole
    /// bounds matches what the menu draws behind a plain item, whose row is exactly this wide.
    override func draw(_ dirtyRect: NSRect) {
        // Under the highlight, not over it: a hairline in separator colour drawn across the
        // selection fill would read as a grey line through the selected row.
        if drawsDivider {
            NSColor.separatorColor.setFill()
            NSRect(x: Self.padding, y: bounds.height - 1, width: bounds.width - Self.padding * 2, height: 1).fill()
        }
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

    @objc private func pinTapped() {
        onTogglePin?()
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
