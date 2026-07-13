import AppKit

final class ErrorStateView: NSVisualEffectView {
    enum Kind: Equatable {
        case fatal
        case recoverable
    }

    var onChooseAnother: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let messageLabel = NSTextField(wrappingLabelWithString: "Unable to play this video.")
    private let chooseButton = NSButton(title: "Choose Another Video…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Diagnostics", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private var presentedMessage: String?
    private var presentedKind: Kind?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)

        messageLabel.textColor = .labelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3

        chooseButton.target = self
        chooseButton.action = #selector(chooseAnother)
        chooseButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics)
        copyButton.bezelStyle = .rounded
        dismissButton.target = self
        dismissButton.action = #selector(dismissError)
        dismissButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [chooseButton, dismissButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(message: String, kind: Kind) {
        let shouldAnnounce = isHidden || message != presentedMessage || kind != presentedKind
        presentedMessage = message
        presentedKind = kind
        isHidden = false
        messageLabel.stringValue = message
        setAccessibilityLabel(message)
        chooseButton.isHidden = kind != .fatal
        dismissButton.isHidden = kind != .recoverable

        if shouldAnnounce {
            NSAccessibility.post(
                element: self,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSNumber(value: NSAccessibilityPriorityLevel.high.rawValue)
                ]
            )
        }
    }

    @objc private func chooseAnother() { onChooseAnother?() }
    @objc private func copyDiagnostics() { onCopyDiagnostics?() }
    @objc private func dismissError() { onDismiss?() }
}
