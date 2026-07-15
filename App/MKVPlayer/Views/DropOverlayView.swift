import AppKit

final class DropOverlayView: NSVisualEffectView {
    private let symbolView = NSImageView(frame: .zero)
    private let messageLabel = NSTextField(labelWithString: "Drop video to open")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 16
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)

        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        symbolView.contentTintColor = .labelColor
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        messageLabel.textColor = .labelColor
        messageLabel.alignment = .center

        let content = NSStackView(views: [symbolView, messageLabel])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(message: String, isValid: Bool) {
        messageLabel.stringValue = message
        symbolView.image = NSImage(
            systemSymbolName: isValid ? "play.rectangle.on.rectangle" : "exclamationmark.triangle",
            accessibilityDescription: nil
        )
        let color = isValid ? NSColor.controlAccentColor : NSColor.systemOrange
        layer?.borderColor = color.cgColor
        setAccessibilityLabel(message)
        isHidden = false
    }
}
