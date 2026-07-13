import AppKit

final class ActionButton: NSButton {
    var handler: (() -> Void)?

    convenience init(
        symbolName: String,
        accessibilityLabel: String,
        toolTip: String,
        bezelStyle: NSButton.BezelStyle = .accessoryBarAction,
        handler: (() -> Void)? = nil
    ) {
        self.init(frame: .zero)
        self.handler = handler
        self.bezelStyle = bezelStyle
        self.isBordered = false
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        self.imagePosition = .imageOnly
        self.toolTip = toolTip
        self.setAccessibilityLabel(accessibilityLabel)
        self.target = self
        self.action = #selector(invoke)
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }

    @objc private func invoke() {
        handler?()
    }
}

final class ActionPopUpButton: NSPopUpButton {
    var selectionHandler: ((Int) -> Void)?

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        target = self
        action = #selector(selectionChanged)
        translatesAutoresizingMaskIntoConstraints = false
        controlSize = .small
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func selectionChanged() {
        selectionHandler?(indexOfSelectedItem)
    }
}

final class TrackingSlider: NSSlider {
    var valueChanged: ((Double) -> Void)?
    var trackingChanged: ((Bool) -> Void)?
    var committed: ((Double) -> Void)?

    private var isTrackingPointer = false

    convenience init(value: Double, minValue: Double, maxValue: Double) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        doubleValue = value
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isContinuous = true
        target = self
        action = #selector(sliderValueDidChange)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingPointer = true
        trackingChanged?(true)
        super.mouseDown(with: event)
        trackingChanged?(false)
        isTrackingPointer = false
        committed?(doubleValue)
    }

    @objc private func sliderValueDidChange() {
        // Keyboard arrows and accessibility increment/decrement actions do not
        // enter mouseDown. Treat each of those actions as a complete scrub so
        // the session receives both a preview and a committed seek.
        if !isTrackingPointer {
            trackingChanged?(true)
        }
        valueChanged?(doubleValue)
        if !isTrackingPointer {
            trackingChanged?(false)
            committed?(doubleValue)
        }
    }
}
