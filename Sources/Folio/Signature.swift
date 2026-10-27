import AppKit
import PDFKit

// MARK: - Données

/// Signatures de l'utilisateur : dessin manuscrit + nom en écriture cursive.
struct SignatureProfile: Codable {
    var strokes: [[[Double]]] = []
    var name: String = ""
    var fontName: String = "SnellRoundhand"

    var drawnStrokes: [[NSPoint]] {
        strokes
            .map { stroke in stroke.compactMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil } }
            .filter { !$0.isEmpty }
    }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasDrawn: Bool { !drawnStrokes.isEmpty }
    var hasName: Bool { !trimmedName.isEmpty }
    var isEmpty: Bool { !hasDrawn && !hasName }
}

enum SignatureStyle: Int, CaseIterable {
    case drawn, typed, stacked, sideBySide

    var title: String {
        switch self {
        case .drawn: return "Signature manuscrite"
        case .typed: return "Nom"
        case .stacked: return "Signature + nom dessous"
        case .sideBySide: return "Nom + signature côte à côte"
        }
    }

    func isAvailable(_ p: SignatureProfile) -> Bool {
        switch self {
        case .drawn: return p.hasDrawn
        case .typed: return p.hasName
        case .stacked, .sideBySide: return p.hasDrawn && p.hasName
        }
    }
}

enum SignatureFonts {
    static let candidates: [(postScript: String, label: String)] = [
        ("SnellRoundhand", "Snell Roundhand"),
        ("SavoyeLetPlain", "Savoye"),
        ("Zapfino", "Zapfino"),
        ("Apple-Chancery", "Apple Chancery"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Noteworthy-Light", "Noteworthy"),
    ]

    static var available: [(postScript: String, label: String)] {
        candidates.filter { NSFont(name: $0.postScript, size: 12) != nil }
    }

    static func font(_ name: String, size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? NSFont(name: "SnellRoundhand", size: size) ?? .systemFont(ofSize: size)
    }
}

/// Enregistrées localement dans ~/Library/Application Support/Folio/signature.json
enum SignatureStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Folio", isDirectory: true).appendingPathComponent("signature.json")
    }

    static func load() -> SignatureProfile {
        guard let data = try? Data(contentsOf: url) else { return SignatureProfile() }
        if let profile = try? JSONDecoder().decode(SignatureProfile.self, from: data) { return profile }
        // Ancien format (dessin seul)
        if let strokes = try? JSONDecoder().decode([[[Double]]].self, from: data) {
            var p = SignatureProfile()
            p.strokes = strokes
            return p
        }
        return SignatureProfile()
    }

    static func save(_ profile: SignatureProfile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Rendu

enum SignatureRenderer {
    static let inkWidth: CGFloat = 2.2

    private struct Block {
        let size: NSSize
        let draw: (NSPoint) -> Void
    }

    private static func drawnBlock(_ strokes: [[NSPoint]], height: CGFloat, color: NSColor) -> Block {
        let all = strokes.flatMap { $0 }
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 1
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 1
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        var s = height / h
        if w * s > height * 5 { s = height * 5 / w }
        let pad = inkWidth * 2
        let size = NSSize(width: w * s + 2 * pad, height: h * s + 2 * pad)
        return Block(size: size) { o in
            color.setStroke()
            for stroke in strokes {
                let pts = stroke.map { NSPoint(x: o.x + pad + ($0.x - minX) * s, y: o.y + pad + ($0.y - minY) * s) }
                AnnotationFactory.smoothPath(pts, width: inkWidth).stroke()
            }
        }
    }

    private static func textBlock(_ text: String, font: NSFont, color: NSColor) -> Block {
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let r = str.boundingRect(with: NSSize(width: 4000, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: ceil(r.width) + 10, height: ceil(r.height) + 6)
        return Block(size: size) { o in
            str.draw(with: NSRect(x: o.x + 5, y: o.y + 3, width: ceil(r.width) + 2, height: ceil(r.height)),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// Image vectorielle de la signature dans le style demandé.
    static func image(_ style: SignatureStyle, profile p: SignatureProfile, color: NSColor) -> NSImage? {
        guard style.isAvailable(p) else { return nil }
        let block: Block
        switch style {
        case .drawn:
            block = drawnBlock(p.drawnStrokes, height: 60, color: color)
        case .typed:
            block = textBlock(p.trimmedName, font: SignatureFonts.font(p.fontName, size: 34), color: color)
        case .stacked:
            let d = drawnBlock(p.drawnStrokes, height: 60, color: color)
            let t = textBlock(p.trimmedName, font: SignatureFonts.font(p.fontName, size: 22), color: color)
            let size = NSSize(width: max(d.size.width, t.size.width), height: d.size.height + t.size.height)
            block = Block(size: size) { o in
                d.draw(NSPoint(x: o.x + (size.width - d.size.width) / 2, y: o.y + t.size.height))
                t.draw(NSPoint(x: o.x + (size.width - t.size.width) / 2, y: o.y))
            }
        case .sideBySide:
            let t = textBlock(p.trimmedName, font: SignatureFonts.font(p.fontName, size: 30), color: color)
            let d = drawnBlock(p.drawnStrokes, height: max(40, t.size.height), color: color)
            let gap: CGFloat = 16
            let size = NSSize(width: t.size.width + gap + d.size.width, height: max(t.size.height, d.size.height))
            block = Block(size: size) { o in
                t.draw(NSPoint(x: o.x, y: o.y + (size.height - t.size.height) / 2))
                d.draw(NSPoint(x: o.x + t.size.width + gap, y: o.y + (size.height - d.size.height) / 2))
            }
        }
        return NSImage(size: block.size, flipped: false) { _ in
            block.draw(.zero)
            return true
        }
    }

    /// Petite version pour les menus.
    static func thumbnail(_ image: NSImage, maxWidth: CGFloat = 170, maxHeight: CGFloat = 30) -> NSImage {
        var s = maxHeight / max(image.size.height, 1)
        if image.size.width * s > maxWidth { s = maxWidth / max(image.size.width, 1) }
        let size = NSSize(width: image.size.width * s, height: image.size.height * s)
        return NSImage(size: size, flipped: false) { r in
            image.draw(in: r)
            return true
        }
    }
}

/// Tampon dont l'apparence est la signature (nom cursif ou signature combinée).
final class SignatureStampAnnotation: PDFAnnotation {
    private var image: NSImage?

    convenience init(bounds: NSRect, image: NSImage) {
        self.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.image = image
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image else {
            super.draw(with: box, in: context)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Interface

/// Zone où l'on dessine la signature au trackpad ou à la souris.
final class SignatureCanvas: NSView {
    private(set) var strokes: [[NSPoint]] = []
    private var current: [NSPoint] = []

    var isEmpty: Bool { strokes.isEmpty }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Affiche une signature déjà enregistrée, centrée.
    func setStrokes(_ s: [[NSPoint]]) {
        let all = s.flatMap { $0 }
        guard !all.isEmpty else { strokes = []; needsDisplay = true; return }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let dx = (bounds.width - (maxX - minX)) / 2 - minX
        let dy = (bounds.height - (maxY - minY)) / 2 - minY
        strokes = s.map { $0.map { NSPoint(x: $0.x + dx, y: $0.y + dy) } }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(white: 0.85, alpha: 1).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: 24, y: 40))
        baseline.line(to: NSPoint(x: bounds.width - 24, y: 40))
        baseline.lineWidth = 1
        baseline.stroke()
        NSColor.black.setStroke()
        for s in strokes + [current] where !s.isEmpty {
            AnnotationFactory.smoothPath(s, width: 2.5).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        current = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !current.isEmpty { strokes.append(current) }
        current = []
        needsDisplay = true
    }

    func clear() {
        strokes = []
        current = []
        needsDisplay = true
    }
}

/// Feuille « Mes signatures » : signature manuscrite + nom en cursive.
final class SignatureManagerController: NSWindowController, NSTextFieldDelegate {
    private let canvas = SignatureCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 170))
    private let nameField = NSTextField()
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview = NSTextField(labelWithString: "")
    private let fonts = SignatureFonts.available
    private var profile = SignatureStore.load()

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        let title = NSTextField(labelWithString: "Mes signatures")
        title.font = .boldSystemFont(ofSize: 15)

        let drawnLabel = NSTextField(labelWithString: "1. Signature manuscrite — dessinez avec le trackpad ou la souris")
        drawnLabel.font = .boldSystemFont(ofSize: 12)
        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        canvas.translatesAutoresizingMaskIntoConstraints = false
        let clearButton = NSButton(title: "Effacer le dessin", target: self, action: #selector(clearDrawing))

        let separator = NSBox()
        separator.boxType = .separator

        let nameLabel = NSTextField(labelWithString: "2. Nom en écriture cursive")
        nameLabel.font = .boldSystemFont(ofSize: 12)
        nameField.placeholderString = "Prénom Nom"
        nameField.stringValue = profile.name
        nameField.delegate = self
        for f in fonts { fontPopup.addItem(withTitle: f.label) }
        if let i = fonts.firstIndex(where: { $0.postScript == profile.fontName }) { fontPopup.selectItem(at: i) }
        fontPopup.target = self
        fontPopup.action = #selector(updatePreview)
        let nameRow = NSStackView(views: [nameField, fontPopup])
        nameRow.orientation = .horizontal
        preview.lineBreakMode = .byTruncatingTail

        let hint = NSTextField(wrappingLabelWithString: "Au moment de signer, vous choisissez : signature manuscrite, nom, ou les deux combinés (nom dessous ou côte à côte).")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let cancelButton = NSButton(title: "Annuler", target: self, action: #selector(cancelManager))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Enregistrer", target: self, action: #selector(saveManager))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, drawnLabel, canvas, clearButton, separator, nameLabel, nameRow, preview, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: clearButton)
        stack.setCustomSpacing(16, after: separator)

        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(equalToConstant: 520),
            canvas.heightAnchor.constraint(equalToConstant: 170),
            separator.widthAnchor.constraint(equalTo: canvas.widthAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 300),
            preview.widthAnchor.constraint(equalTo: canvas.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 60),
            hint.widthAnchor.constraint(equalTo: canvas.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: canvas.widthAnchor),
        ])
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        stack.layoutSubtreeIfNeeded()
        canvas.setStrokes(profile.drawnStrokes)
        updatePreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private var selectedFont: String {
        let i = fontPopup.indexOfSelectedItem
        return fonts.indices.contains(i) ? fonts[i].postScript : profile.fontName
    }

    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    @objc private func updatePreview() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preview.font = SignatureFonts.font(selectedFont, size: 32)
        preview.stringValue = name.isEmpty ? "Prénom Nom" : name
        preview.textColor = name.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    @objc private func clearDrawing() { canvas.clear() }

    @objc private func cancelManager() { finish(.cancel) }

    @objc private func saveManager() {
        var p = profile
        let all = canvas.strokes.flatMap { $0 }
        let minX = all.map(\.x).min() ?? 0
        let minY = all.map(\.y).min() ?? 0
        p.strokes = canvas.strokes.map { $0.map { [Double($0.x - minX), Double($0.y - minY)] } }
        p.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        p.fontName = selectedFont
        guard !p.isEmpty else { NSSound.beep(); return }
        SignatureStore.save(p)
        finish(.OK)
    }

    private func finish(_ code: NSApplication.ModalResponse) {
        guard let w = window else { return }
        if let parent = w.sheetParent { parent.endSheet(w, returnCode: code) } else { w.close() }
    }
}
