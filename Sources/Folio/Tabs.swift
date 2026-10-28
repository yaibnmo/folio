import AppKit

/// Onglets « façon navigateur » : chaque PDF garde sa propre fenêtre (barre d'outils, feuilles d'enregistrement…),
/// mais une seule est visible à la fois, au même emplacement ; la barre d'onglets permet de passer de l'une à l'autre.
final class TabManager {
    static let shared = TabManager()

    private(set) var tabs: [DocumentWindowController] = []
    private(set) weak var active: DocumentWindowController?

    func add(_ wc: DocumentWindowController) {
        if !tabs.contains(where: { $0 === wc }) {
            if let a = active, let i = tabs.firstIndex(where: { $0 === a }) {
                tabs.insert(wc, at: i + 1)
            } else {
                tabs.append(wc)
            }
        }
        select(wc)
    }

    func select(_ wc: DocumentWindowController) {
        guard let window = wc.window else { return }
        let previous = active
        active = wc
        if let p = previous, p !== wc, let pw = p.window, pw.isVisible {
            if !pw.styleMask.contains(.fullScreen) && !window.styleMask.contains(.fullScreen) {
                window.setFrame(pw.frame, display: false)
            }
            window.makeKeyAndOrderFront(nil)
            pw.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        refresh()
    }

    func remove(_ wc: DocumentWindowController) {
        guard let i = tabs.firstIndex(where: { $0 === wc }) else { return }
        let wasActive = active === wc
        let frame = wc.window?.frame
        tabs.remove(at: i)
        if wasActive {
            active = nil
            if !tabs.isEmpty {
                let next = tabs[min(i, tabs.count - 1)]
                if let frame, let w = next.window, !w.styleMask.contains(.fullScreen) { w.setFrame(frame, display: false) }
                select(next)
            }
        }
        refresh()
    }

    /// Ferme un onglet (avec la demande d'enregistrement habituelle si besoin).
    func close(_ wc: DocumentWindowController) {
        if active !== wc { select(wc) }
        wc.window?.performClose(nil)
    }

    func selectNext(_ step: Int) {
        guard tabs.count > 1, let a = active, let i = tabs.firstIndex(where: { $0 === a }) else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    func refresh() {
        for wc in tabs { wc.tabStrip.reload(tabs: tabs, active: active) }
    }
}

/// Un onglet : nom du PDF, puis × à droite.
private final class TabItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton(frame: .zero)
    private let selected: Bool
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, edited: Bool, selected: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.selected = selected
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = title

        label.stringValue = (edited ? "• " : "") + title
        label.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer l'onglet")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Fermer l'onglet (⌘W)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        let preferred = widthAnchor.constraint(equalToConstant: 220)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferred,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        if selected {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { onSelect() }
    }

    /// Clic du milieu : ferme l'onglet, comme dans un navigateur.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() }
    }

    @objc private func closeClicked() { onClose() }
}

/// Barre d'onglets placée sous la barre d'outils de chaque fenêtre de document.
final class TabStripView: NSView {
    private let stack = NSStackView()
    private let plusButton = NSButton(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 34))
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Nouvel onglet")
        plusButton.isBordered = false
        plusButton.bezelStyle = .regularSquare
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = "Ouvrir un PDF dans un nouvel onglet (⌘T)"
        plusButton.target = nil
        plusButton.action = #selector(NSResponder.newWindowForTab(_:))
        plusButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 24),
            plusButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    func reload(tabs: [DocumentWindowController], active: DocumentWindowController?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for wc in tabs {
            let doc = wc.document as? NSDocument
            let item = TabItemView(title: doc?.displayName ?? "PDF",
                                   edited: doc?.isDocumentEdited ?? false,
                                   selected: wc === active,
                                   onSelect: { [weak wc] in if let wc { TabManager.shared.select(wc) } },
                                   onClose: { [weak wc] in if let wc { TabManager.shared.close(wc) } })
            stack.addArrangedSubview(item)
        }
        stack.addArrangedSubview(plusButton)
    }
}
