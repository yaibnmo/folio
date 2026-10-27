import AppKit
import PDFKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Vue racine de l'accueil : accepte les PDF glissés depuis le Finder.
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private func pdfURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !pdfURLs(sender).isEmpty
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = pdfURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if highlighted {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
            p.lineWidth = 3
            p.stroke()
        }
    }
}

/// Une ligne de fichier (miniature, nom, dossier, date, étoile).
private final class FileRowView: NSView {
    let url: URL
    var onOpen: (() -> Void)?
    private let thumb = NSImageView()
    private let pinButton: NSButton
    private var hovering = false { didSet { needsDisplay = true } }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f
    }()

    init(url: URL, date: Date?, pinned: Bool) {
        self.url = url
        let star = NSImage(systemSymbolName: pinned ? "star.fill" : "star", accessibilityDescription: pinned ? "Désépingler" : "Épingler") ?? NSImage()
        pinButton = NSButton(image: star, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pinButton.target = self
        pinButton.action = #selector(togglePin)

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.white.cgColor
        thumb.layer?.borderWidth = 0.5
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.image = ThumbnailCache.shared.image(for: url) { [weak self] img in self?.thumb.image = img }
            ?? NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)

        let name = NSTextField(labelWithString: url.deletingPathExtension().lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [name, folder])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let when = NSTextField(labelWithString: date.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? "")
        when.font = .systemFont(ofSize: 11)
        when.textColor = .secondaryLabelColor

        pinButton.isBordered = false
        pinButton.contentTintColor = pinned ? .systemYellow : .tertiaryLabelColor
        pinButton.toolTip = pinned ? "Désépingler de l'accueil" : "Épingler sur l'accueil"

        for v in [thumb, texts, when, pinButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 62),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 36),
            thumb.heightAnchor.constraint(equalToConstant: 48),
            texts.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: when.leadingAnchor, constant: -12),
            when.centerYAnchor.constraint(equalTo: centerYAnchor),
            when.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -12),
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if pinButton.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Ouvrir") { [weak self] in self?.onOpen?() })
        menu.addItem(MenuAction.item("Afficher dans le Finder") { [url] in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        menu.addItem(.separator())
        let pinned = LibraryStore.shared.isPinned(url)
        menu.addItem(MenuAction.item(pinned ? "Désépingler de l'accueil" : "Épingler sur l'accueil") { [url] in
            LibraryStore.shared.togglePin(url)
        })
        menu.addItem(MenuAction.item("Retirer des récents") { [url] in
            LibraryStore.shared.removeRecent(url)
        })
        return menu
    }

    @objc private func togglePin() { LibraryStore.shared.togglePin(url) }
}

/// Écran d'accueil : fichiers épinglés et récents.
final class HomeWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    static let shared = HomeWindowController()

    private let listStack = NSStackView()
    private let filterField = NSSearchField()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Folio"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 420)
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
        _ = window.setFrameAutosaveName("FolioHome")
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: LibraryStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }

    private func build() {
        guard let window else { return }
        let root = DropView(frame: window.contentRect(forFrameRect: window.frame))
        root.onDrop = { [weak self] urls in urls.forEach { self?.open($0) } }
        window.contentView = root

        let title = NSTextField(labelWithString: "Folio")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Vos PDF récents — glissez un fichier ici pour l'ouvrir")
        subtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        filterField.placeholderString = "Filtrer"
        filterField.delegate = self
        let openButton = NSButton(title: "Ouvrir un PDF…", target: self, action: #selector(openPanel))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titles, spacer, filterField, openButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        listStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)

        let clearButton = NSButton(title: "Effacer l'historique", target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .inline
        clearButton.controlSize = .small
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [clearButton, footerSpacer])
        footer.orientation = .horizontal

        for v in [header, scroll, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            filterField.widthAnchor.constraint(equalToConstant: 180),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    // MARK: Liste

    @objc func reload() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let fm = FileManager.default
        let filter = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        func keep(_ u: URL) -> Bool {
            fm.fileExists(atPath: u.path) && (filter.isEmpty || u.lastPathComponent.lowercased().contains(filter))
        }

        let library = LibraryStore.shared
        let pinned = library.pinned.filter(keep)
        var recents = library.recents.filter { keep($0.url) }
        for u in NSDocumentController.shared.recentDocumentURLs
        where keep(u) && !recents.contains(where: { $0.url.path == u.path }) {
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            recents.append(LibraryStore.Entry(url: u, date: date))
        }
        recents = recents.filter { r in !pinned.contains { $0.path == r.url.path } }

        if !pinned.isEmpty {
            addSection("Épinglés")
            pinned.forEach { addRow($0, date: library.lastOpened($0), pinned: true) }
        }
        addSection("Récents")
        if recents.isEmpty {
            let empty = NSTextField(labelWithString: filter.isEmpty
                                    ? "Aucun fichier récent. Cliquez sur « Ouvrir un PDF… » ou glissez un fichier ici."
                                    : "Aucun fichier ne correspond au filtre.")
            empty.textColor = .secondaryLabelColor
            addPadded(empty)
        }
        recents.forEach { addRow($0.url, date: $0.date == .distantPast ? nil : $0.date, pinned: false) }
    }

    private func addPadded(_ v: NSView) {
        let box = NSStackView(views: [v])
        box.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 6, right: 14)
        listStack.addArrangedSubview(box)
    }

    private func addSection(_ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addPadded(label)
    }

    private func addRow(_ url: URL, date: Date?, pinned: Bool) {
        let row = FileRowView(url: url, date: date, pinned: pinned)
        row.onOpen = { [weak self] in self?.open(url) }
        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Actions

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    @objc private func openPanel() {
        NSDocumentController.shared.openDocument(nil)
    }

    @objc private func clearHistory() {
        LibraryStore.shared.clearRecents()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
