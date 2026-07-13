import AppKit

final class EmptyStateView: NSView {
    var onOpen: (() -> Void)?

    private let openButton = NSButton(title: "Open Video…", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "or drop a video here")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.target = self
        openButton.action = #selector(openVideo)
        openButton.setAccessibilityLabel("Open Video")

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        let stack = NSStackView(views: [openButton, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func openVideo() {
        onOpen?()
    }
}
