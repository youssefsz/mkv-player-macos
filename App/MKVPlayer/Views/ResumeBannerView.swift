import AppKit

final class ResumeBannerView: NSVisualEffectView {
    var onRestart: (() -> Void)?

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)

        let restart = NSButton(title: "Restart", target: self, action: #selector(restartPlayback))
        restart.bezelStyle = .inline
        let stack = NSStackView(views: [label, restart])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func show(position: TimeInterval) -> String {
        let message = "Resumed at \(TimeText.format(position))"
        label.stringValue = message
        setAccessibilityLabel(message)
        isHidden = false
        return message
    }

    @objc private func restartPlayback() { onRestart?() }
}
