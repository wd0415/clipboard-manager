import AppKit

/// One history entry, drawn as a menu row.
///
/// Hosting a custom view in an `NSMenuItem` gives up two behaviours a plain item provides, and
/// both are restored here on purpose:
///
/// - The menu no longer performs click-to-select for the row, so `mouseDown` selects explicitly.
/// - The delete button cannot be revealed with an `NSTrackingArea`. Measured while a menu is
///   tracking, a tracking area fires only when the pointer crosses into it during a move and
///   misses when the pointer arrives directly, so the reveal would be intermittent.
///   `NSMenuDelegate.menu(_:willHighlight:)` is reliable and fires for arrow-key selection too,
///   which is exactly the "hovered or selected" behaviour asked for.
@MainActor
final class HistoryRowView: NSView {
    static let height: CGFloat = 24
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let deleteSize: CGFloat = 16
    private static let thumbnailSize: CGFloat = 18

    private let titleField = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?

    /// Set by the menu delegate when this row becomes the highlighted one.
    var showsDelete = false {
        didSet { deleteButton.isHidden = !showsDelete }
    }

    var deleteButtonFrame: NSRect { deleteButton.frame }

    /// Space left for the title once the thumbnail, the delete button and the margins are taken.
    /// The controller needs this to truncate before handing text over, because a label clips
    /// rather than ellipsizing.
    static func titleWidth(hasThumbnail: Bool, totalWidth: CGFloat) -> CGFloat {
        let leading = hasThumbnail ? padding + thumbnailSize + gap : padding
        return totalWidth - padding - deleteSize - gap - leading
    }

    init(title: String, thumbnail: NSImage?, totalWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: Self.height))

        var titleOriginX = Self.padding
        if let thumbnail {
            thumbnailView.image = thumbnail
            thumbnailView.imageScaling = .scaleProportionallyUpOrDown
            thumbnailView.frame = NSRect(
                x: Self.padding,
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
        previousButton.isEnabled = page > 1
        nextButton.isEnabled = page < pageCount

        pageLabel.stringValue = "第 \(page)/\(pageCount) 页"
        pageLabel.font = .menuFont(ofSize: 0)
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
