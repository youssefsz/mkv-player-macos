import AppKit

final class PlaybackQueueView: NSVisualEffectView {
    var onClose: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onSelectItem: ((UUID) -> Void)?
    var onRemoveItem: ((UUID) -> Void)?

    private let rows = NSStackView()
    private let previousButton = ActionButton(
        symbolName: "backward.end.fill",
        accessibilityLabel: "Previous video",
        toolTip: "Previous Video"
    )
    private let nextButton = ActionButton(
        symbolName: "forward.end.fill",
        accessibilityLabel: "Next video",
        toolTip: "Next Video"
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("Playback queue")

        let title = NSTextField(labelWithString: "Queue")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        previousButton.handler = { [weak self] in self?.onPrevious?() }
        nextButton.handler = { [weak self] in self?.onNext?() }

        let closeButton = ActionButton(
            symbolName: "xmark",
            accessibilityLabel: "Close queue",
            toolTip: "Close Queue"
        ) { [weak self] in
            self?.onClose?()
        }

        let header = NSStackView(views: [title, NSView(), previousButton, nextButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rows

        addSubview(header)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            rows.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            widthAnchor.constraint(equalToConstant: 310),
            heightAnchor.constraint(equalToConstant: 190)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: PlayerPresentationState) {
        previousButton.isEnabled = state.canPlayPreviousQueueItem
        nextButton.isEnabled = state.canPlayNextQueueItem

        rows.arrangedSubviews.forEach { view in
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in state.queueItems {
            let row = PlaybackQueueRowView(item: item)
            row.onSelect = { [weak self] in self?.onSelectItem?(item.id) }
            row.onRemove = { [weak self] in self?.onRemoveItem?(item.id) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
}

private final class PlaybackQueueRowView: NSView {
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?

    init(item: PlayerQueueItemPresentation) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let selectButton = NSButton(title: item.title, target: nil, action: nil)
        selectButton.bezelStyle = .inline
        selectButton.isBordered = false
        selectButton.alignment = .left
        selectButton.lineBreakMode = .byTruncatingMiddle
        selectButton.imagePosition = .imageLeading
        selectButton.image = item.isCurrent
            ? NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Currently playing")
            : NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        selectButton.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: item.isCurrent ? .semibold : .regular
        )
        selectButton.contentTintColor = item.isCurrent ? .controlAccentColor : .labelColor
        selectButton.toolTip = item.url.path
        selectButton.setAccessibilityLabel(
            item.isCurrent ? "\(item.title), currently playing" : item.title
        )
        selectButton.target = self
        selectButton.action = #selector(selectItem)
        selectButton.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = ActionButton(
            symbolName: "xmark.circle",
            accessibilityLabel: "Remove \(item.title) from queue",
            toolTip: "Remove from Queue"
        ) { [weak self] in
            self?.onRemove?()
        }

        let content = NSStackView(views: [selectButton, removeButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func selectItem() { onSelect?() }
}
