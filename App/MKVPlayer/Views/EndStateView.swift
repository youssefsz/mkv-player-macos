import AppKit

final class EndStateView: NSVisualEffectView {
    var onReplay: (() -> Void)?
    var onOpenAnother: (() -> Void)?

    private let headingLabel = NSTextField(labelWithString: "Finished Playing")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let replayButton = NSButton(title: "Replay", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Another…", target: nil, action: nil)
    private var presentedFilename: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)

        headingLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        headingLabel.textColor = .labelColor
        headingLabel.alignment = .center

        filenameLabel.textColor = .secondaryLabelColor
        filenameLabel.alignment = .center
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        replayButton.bezelStyle = .rounded
        replayButton.controlSize = .large
        replayButton.keyEquivalent = "\r"
        replayButton.keyEquivalentModifierMask = []
        replayButton.target = self
        replayButton.action = #selector(replay)
        replayButton.setAccessibilityLabel("Replay video")

        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.target = self
        openButton.action = #selector(openAnother)
        openButton.setAccessibilityLabel("Open another video")

        let buttons = NSStackView(views: [openButton, replayButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let content = NSStackView(views: [headingLabel, filenameLabel, buttons])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            replayButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(filename: String?) {
        isHidden = false
        filenameLabel.stringValue = filename ?? ""
        filenameLabel.isHidden = filename?.isEmpty != false
        setAccessibilityLabel(
            filename.map { "Finished playing \($0)" } ?? "Finished playing"
        )

        guard presentedFilename != filename else { return }
        presentedFilename = filename
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: accessibilityLabel() ?? "Finished playing",
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue)
            ]
        )
    }

    func dismiss() {
        isHidden = true
        presentedFilename = nil
    }

    @objc private func replay() { onReplay?() }
    @objc private func openAnother() { onOpenAnother?() }
}
