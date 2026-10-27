import AppKit
import PDFKit

protocol FolioPDFViewHost: AnyObject {
    func pdfViewWantsTool(_ tool: Tool)
    func pdfViewSelectionChanged(_ annotation: PDFAnnotation?)
    func pdfViewWantsSignatureManager()
    func pdfViewDidPlaceSignature()
    func pdfViewColor(for tool: Tool) -> NSColor
    func pdfViewIsFavorite(pageIndex: Int) -> Bool
    func pdfViewToggleFavorite(pageIndex: Int)
}

/// Cadre pointillé autour de l'annotation sélectionnée (+ poignée de redimensionnement).
final class SelectionOverlay: NSView {
    var showsHandle = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 1.5
        let dash: [CGFloat] = [4, 3]
        path.setLineDash(dash, count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSColor.controlAccentColor.setFill()
        for c in [NSPoint(x: 0, y: 0), NSPoint(x: bounds.maxX - 6, y: 0), NSPoint(x: 0, y: bounds.maxY - 6), NSPoint(x: bounds.maxX - 6, y: bounds.maxY - 6)] {
            NSBezierPath(rect: NSRect(origin: c, size: NSSize(width: 6, height: 6))).fill()
        }
        if showsHandle {
            NSColor.white.setFill()
            let h = NSRect(x: bounds.maxX - 11, y: 0, width: 11, height: 11)
            NSBezierPath(ovalIn: h).fill()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: h.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// PDFView + outils d'annotation.
final class FolioPDFView: PDFView {
    weak var host: FolioPDFViewHost?

    var tool: Tool = .select {
        didSet {
            if oldValue != tool { endTextEditing() }
            if tool != .select, selectedAnnotation != nil { selectedAnnotation = nil }
        }
    }
    var color: NSColor = .black
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 14
    var signatureColor: NSColor = Tool.signature.defaultColor

    // Édition directe des zones de texte (voir TextEditing.swift)
    var textEditor: NSTextView?
    var textEditing: TextEditSession?
    let formatBar = TextFormatBar()
    let textDelegate = TextEditorDelegate()
    var currentTextFormat = TextFormat.last

    private(set) var selectedAnnotation: PDFAnnotation? {
        didSet {
            refreshOverlay()
            host?.pdfViewSelectionChanged(selectedAnnotation)
        }
    }

    private enum Drag {
        case none
        case move(PDFAnnotation, PDFPage, start: NSPoint, original: NSRect)
        case resize(PDFAnnotation, PDFPage, original: NSRect)
        case shape(PDFPage, points: [NSPoint], preview: PDFAnnotation?)
    }

    private var drag: Drag = .none
    private let overlay = SelectionOverlay(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setUp() {
        overlay.isHidden = true
        addSubview(overlay)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(geometryChanged(_:)), name: .PDFViewScaleChanged, object: self)
        nc.addObserver(self, selector: #selector(geometryChanged(_:)), name: .PDFViewDisplayModeChanged, object: self)
        nc.addObserver(self, selector: #selector(geometryChanged(_:)), name: NSView.boundsDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(documentDidChange(_:)), name: .PDFViewDocumentChanged, object: self)
    }

    // MARK: - Overlay de sélection

    @objc private func geometryChanged(_ note: Notification) {
        if note.name == NSView.boundsDidChangeNotification {
            guard let v = note.object as? NSView, v.isDescendant(of: self), v !== textEditor else { return }
        }
        if note.name == .PDFViewScaleChanged { styleTextEditor() }
        refreshOverlay()
    }

    @objc private func documentDidChange(_ note: Notification) {
        endTextEditing()
        selectedAnnotation = nil
    }

    override func layout() {
        super.layout()
        refreshOverlay()
    }

    private func ensureOverlayOnTop() {
        if subviews.last !== overlay {
            overlay.removeFromSuperview()
            addSubview(overlay)
        }
        refreshOverlay()
    }

    func refreshOverlay() {
        if textEditor != nil {
            overlay.isHidden = true
            layoutTextEditor()
            return
        }
        updateFormatBarForSelection()
        guard let a = selectedAnnotation, let page = a.page else {
            overlay.isHidden = true
            return
        }
        overlay.frame = convert(a.bounds, from: page).insetBy(dx: -3, dy: -3)
        overlay.showsHandle = a.isResizable
        overlay.isHidden = false
        overlay.needsDisplay = true
    }

    func select(_ a: PDFAnnotation?) {
        selectedAnnotation = a
        if a != nil { ensureOverlayOnTop() }
    }

    // MARK: - Souris

    private func hitAnnotation(on page: PDFPage, at p: NSPoint) -> PDFAnnotation? {
        for a in page.annotations.reversed() where a.isUserSelectable {
            if a.bounds.insetBy(dx: -3, dy: -3).contains(p) { return a }
        }
        return nil
    }

    private func hitsHandle(_ a: PDFAnnotation, on page: PDFPage, viewPoint vp: NSPoint) -> Bool {
        let corner = convert(NSPoint(x: a.bounds.maxX, y: a.bounds.minY), from: page)
        return abs(vp.x - corner.x) < 10 && abs(vp.y - corner.y) < 10
    }

    override func mouseDown(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        guard let page = page(for: vp, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let pp = convert(vp, to: page)
        if textEditor != nil {
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)

        if tool != .select && tool != .ink, let a = hitAnnotation(on: page, at: pp), a.isMovable {
            host?.pdfViewWantsTool(.select)
            select(a)
            if event.clickCount == 2 { editContents(of: a); return }
            drag = .move(a, page, start: pp, original: a.bounds)
            NSCursor.closedHand.set()
            return
        }

        switch tool {
        case .select:
            if let a = selectedAnnotation, a.page == page, a.isResizable, hitsHandle(a, on: page, viewPoint: vp) {
                drag = .resize(a, page, original: a.bounds)
                return
            }
            if let a = hitAnnotation(on: page, at: pp) {
                select(a)
                if event.clickCount == 2 {
                    editContents(of: a)
                    return
                }
                if a.isMovable {
                    drag = .move(a, page, start: pp, original: a.bounds)
                    NSCursor.closedHand.set()
                }
                return
            }
            select(nil)
            super.mouseDown(with: event)

        case .highlight, .underline, .strike:
            select(nil)
            super.mouseDown(with: event)
            // Si PDFView a suivi la sélection jusqu'au relâchement, on applique tout de suite.
            if NSApp.currentEvent?.type == .leftMouseUp { applyMarkup() }

        case .note:
            addNote(on: page, at: pp)

        case .text:
            addFreeText(on: page, at: pp)

        case .ink, .rect, .oval, .arrow:
            drag = .shape(page, points: [pp], preview: nil)

        case .signature:
            let profile = SignatureStore.load()
            let styles = SignatureStyle.allCases.filter { $0.isAvailable(profile) }
            if styles.isEmpty {
                host?.pdfViewWantsSignatureManager()
            } else if styles.count == 1 {
                placeSignature(styles[0], on: page, at: pp)
            } else {
                _ = signatureMenu(on: page, at: pp).popUp(positioning: nil, at: vp, in: self)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            super.mouseDragged(with: event)

        case let .move(a, page, start, original):
            let p = convert(vp, to: page)
            var r = original
            r.origin.x += p.x - start.x
            r.origin.y += p.y - start.y
            a.bounds = r
            annotationsChanged(on: page)
            refreshOverlay()

        case let .resize(a, page, original):
            let p = convert(vp, to: page)
            var w = max(12, p.x - original.minX)
            var h = max(12, original.maxY - p.y)
            if a.keepsAspectRatio {
                let s = max(w / original.width, 12 / original.height)
                w = original.width * s
                h = original.height * s
            }
            AnnotationGeometry.setBounds(a, to: NSRect(x: original.minX, y: original.maxY - h, width: w, height: h))
            annotationsChanged(on: page)
            refreshOverlay()

        case .shape(let page, var points, let preview):
            let p = convert(vp, to: page)
            if tool == .ink { points.append(p) } else { points = [points[0], p] }
            if let preview { page.removeAnnotation(preview) }
            let next = makeShape(points)
            if let next { page.addAnnotation(next) }
            annotationsChanged(on: page)
            drag = .shape(page, points: points, preview: next)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case .none:
            super.mouseUp(with: event)
            if tool.isMarkup { applyMarkup() }

        case let .move(a, page, _, original):
            if a.bounds != original { registerBoundsUndo(a, on: page, restoreTo: original, actionName: "Déplacer") }

        case let .resize(a, page, original):
            if a.bounds != original { registerBoundsUndo(a, on: page, restoreTo: original, actionName: "Redimensionner") }

        case let .shape(page, points, preview):
            if let preview { page.removeAnnotation(preview) }
            if let a = makeShape(points) {
                insert(a, on: page, actionName: tool.title)
                if tool != .ink {
                    host?.pdfViewWantsTool(.select)
                    select(a)
                }
            } else {
                annotationsChanged(on: page)
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        if tool != .ink, let page = page(for: vp, nearest: false) {
            let pp = convert(vp, to: page)
            if let a = selectedAnnotation, a.page == page, a.isResizable, hitsHandle(a, on: page, viewPoint: vp) {
                NSCursor.crosshair.set()
                return
            }
            if let a = hitAnnotation(on: page, at: pp), a.isMovable {
                NSCursor.openHand.set()
                return
            }
        }
        switch tool {
        case .select, .highlight, .underline, .strike:
            super.mouseMoved(with: event)
        default:
            NSCursor.crosshair.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
        if isDeleteKey, let a = selectedAnnotation, let page = a.page {
            remove(a, from: page, actionName: "Supprimer l'annotation")
            return
        }
        if event.keyCode == 53, selectedAnnotation != nil || tool != .select {
            select(nil)
            host?.pdfViewWantsTool(.select)
            return
        }
        super.keyDown(with: event)
    }

    @objc func deleteSelectedAnnotation(_ sender: Any?) {
        guard let a = selectedAnnotation, let page = a.page else { NSSound.beep(); return }
        remove(a, from: page, actionName: "Supprimer l'annotation")
    }

    // MARK: - Création

    private func makeShape(_ points: [NSPoint]) -> PDFAnnotation? {
        guard let first = points.first, let last = points.last else { return nil }
        switch tool {
        case .ink:
            return AnnotationFactory.ink(strokes: [points], color: color, width: lineWidth)
        case .rect:
            return AnnotationFactory.shape(.square, from: first, to: last, color: color, width: lineWidth)
        case .oval:
            return AnnotationFactory.shape(.circle, from: first, to: last, color: color, width: lineWidth)
        case .arrow:
            return AnnotationFactory.arrow(from: first, to: last, color: color, width: lineWidth)
        default:
            return nil
        }
    }

    private func applyMarkup() {
        guard let sel = currentSelection else { return }
        let subtype: PDFAnnotationSubtype
        switch tool {
        case .highlight: subtype = .highlight
        case .underline: subtype = .underline
        default: subtype = .strikeOut
        }
        mark(sel, subtype, color: color)
    }

    /// Surligne / souligne / barre une sélection de texte (sans changer d'outil).
    func mark(_ sel: PDFSelection, _ subtype: PDFAnnotationSubtype, color: NSColor? = nil) {
        guard let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let tool: Tool = subtype == .highlight ? .highlight : (subtype == .underline ? .underline : .strike)
        let c = color ?? host?.pdfViewColor(for: tool) ?? tool.defaultColor
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5, b.height > 0.5 else { continue }
                insert(AnnotationFactory.markup(subtype, bounds: b, color: c), on: page, actionName: tool.title)
            }
        }
        clearSelection()
    }

    private func addNote(on page: PDFPage, at p: NSPoint) {
        guard let text = Prompt.multiline(title: "Nouvelle note", message: "Texte de la note :") else { return }
        let c = tool == .note ? color : (host?.pdfViewColor(for: .note) ?? Tool.note.defaultColor)
        let a = AnnotationFactory.note(at: p, text: text, color: c)
        insert(a, on: page, actionName: "Note")
        host?.pdfViewWantsTool(.select)
        select(a)
    }

    /// Pose une signature centrée sur le point cliqué.
    func placeSignature(_ style: SignatureStyle, on page: PDFPage, at p: NSPoint) {
        let profile = SignatureStore.load()
        if style == .drawn {
            placeDrawnSignature(profile.drawnStrokes, on: page, at: p)
        } else if let img = SignatureRenderer.image(style, profile: profile, color: signatureColor) {
            var s = 200 / img.size.width
            if img.size.height * s > 80 { s = 80 / img.size.height }
            let w = img.size.width * s, h = img.size.height * s
            let a = SignatureStampAnnotation(bounds: NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), image: img)
            insert(a, on: page, actionName: "Signature")
            select(a)
        }
        host?.pdfViewDidPlaceSignature()
    }

    func signatureMenu(on page: PDFPage, at p: NSPoint) -> NSMenu {
        let menu = NSMenu()
        let profile = SignatureStore.load()
        for style in SignatureStyle.allCases where style.isAvailable(profile) {
            let preview = SignatureRenderer.image(style, profile: profile, color: signatureColor).map { SignatureRenderer.thumbnail($0) }
            menu.addItem(MenuAction.item(style.title, image: preview) { [weak self] in
                self?.placeSignature(style, on: page, at: p)
            })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction.item("Gérer mes signatures…") { [weak self] in
            self?.host?.pdfViewWantsSignatureManager()
        })
        return menu
    }

    private func placeDrawnSignature(_ strokes: [[NSPoint]], on page: PDFPage, at p: NSPoint) {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return }
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 0
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 0
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        var s = 170 / w
        if h * s > 70 { s = 70 / h }
        let placed = strokes.map { stroke in
            stroke.map { NSPoint(x: p.x + ($0.x - minX - w / 2) * s, y: p.y + ($0.y - minY - h / 2) * s) }
        }
        guard let a = AnnotationFactory.ink(strokes: placed, color: signatureColor, width: 1.6) else { return }
        insert(a, on: page, actionName: "Signature")
        select(a)
    }

    // MARK: - Clic droit

    override func menu(for event: NSEvent) -> NSMenu? {
        let selection = currentSelection
        let vp = convert(event.locationInWindow, from: nil)
        let base = super.menu(for: event)
        guard let page = page(for: vp, nearest: true) else { return base }
        let pp = convert(vp, to: page)
        let menu = NSMenu()

        // Texte sélectionné
        if let sel = selection, let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            menu.addItem(MenuAction.item("Surligner") { [weak self] in self?.mark(sel, .highlight) })
            let colors = NSMenu()
            for entry in Palette.colors {
                colors.addItem(MenuAction.item(entry.name, image: Palette.swatch(entry.color)) { [weak self] in
                    self?.mark(sel, .highlight, color: entry.color)
                })
            }
            menu.addItem(MenuAction.submenu("Surligner en", colors))
            menu.addItem(MenuAction.item("Souligner") { [weak self] in self?.mark(sel, .underline) })
            menu.addItem(MenuAction.item("Barrer") { [weak self] in self?.mark(sel, .strikeOut) })
            menu.addItem(MenuAction.item("Ajouter une note sur la sélection") { [weak self] in
                guard let self, let last = sel.selectionsByLine().last, let lp = last.pages.last else { return }
                let b = last.bounds(for: lp)
                self.addNote(on: lp, at: NSPoint(x: b.maxX + 12, y: b.maxY - 4))
            })
            menu.addItem(MenuAction.item("Copier le texte") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
            menu.addItem(.separator())
        }

        // Annotation sous le pointeur
        if let a = hitAnnotation(on: page, at: pp) {
            select(a)
            if a.kind == "Text" || a.kind == "FreeText" {
                menu.addItem(MenuAction.item(a.kind == "Text" ? "Modifier la note…" : "Modifier le texte…") { [weak self] in
                    self?.editContents(of: a)
                })
            }
            let colors = NSMenu()
            for entry in Palette.colors {
                colors.addItem(MenuAction.item(entry.name, image: Palette.swatch(entry.color)) { [weak self] in
                    guard let page = a.page else { return }
                    self?.setColor(entry.color, of: a, on: page)
                })
            }
            if a.kind != "Stamp" { menu.addItem(MenuAction.submenu("Couleur", colors)) }
            menu.addItem(MenuAction.item("Supprimer l'annotation") { [weak self] in
                guard let page = a.page else { return }
                self?.remove(a, from: page, actionName: "Supprimer l'annotation")
            })
            menu.addItem(.separator())
        }

        // Page
        if let index = document?.index(for: page) {
            let favorite = host?.pdfViewIsFavorite(pageIndex: index) ?? false
            let title = favorite ? "Retirer la page \(index + 1) des favoris" : "Ajouter la page \(index + 1) aux favoris"
            menu.addItem(MenuAction.item(title, image: NSImage(systemSymbolName: favorite ? "star.slash" : "star", accessibilityDescription: nil)) { [weak self] in
                self?.host?.pdfViewToggleFavorite(pageIndex: index)
            })
        }
        menu.addItem(MenuAction.item("Ajouter une note ici") { [weak self] in self?.addNote(on: page, at: pp) })
        menu.addItem(MenuAction.item("Ajouter du texte ici") { [weak self] in self?.addFreeText(on: page, at: pp) })
        menu.addItem(MenuAction.submenu("Signer ici", signatureMenu(on: page, at: pp)))

        if let base, !base.items.isEmpty {
            menu.addItem(.separator())
            for item in base.items {
                base.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }

    // MARK: - Modification

    private func editContents(of a: PDFAnnotation) {
        if a.kind == "FreeText", let page = a.page {
            beginTextEditing(a, on: page, isNew: false)
            return
        }
        guard a.kind == "Text", let page = a.page else { return }
        let title = a.kind == "Text" ? "Modifier la note" : "Modifier le texte"
        guard let text = Prompt.multiline(title: title, initial: a.contents ?? "") else { return }
        setText(text, of: a, on: page)
    }

    private func setText(_ text: String, of a: PDFAnnotation, on page: PDFPage) {
        let oldText = a.contents ?? ""
        a.contents = text
        if a.kind == "FreeText", let font = a.font {
            let size = AnnotationFactory.fittingSize(text, font: font)
            let b = a.bounds
            a.bounds = NSRect(x: b.minX, y: b.maxY - size.height, width: size.width, height: size.height)
        }
        annotationsChanged(on: page)
        refreshOverlay()
        undoManager?.registerUndo(withTarget: self) { v in v.setText(oldText, of: a, on: page) }
        undoManager?.setActionName("Modifier le texte")
    }

    func applyColorToSelection(_ c: NSColor) {
        guard let a = selectedAnnotation, let page = a.page else { return }
        setColor(c, of: a, on: page)
    }

    private func setColor(_ c: NSColor, of a: PDFAnnotation, on page: PDFPage) {
        let old = a.displayColor
        switch a.kind {
        case "FreeText": a.fontColor = c
        case "Highlight": a.color = c.withAlphaComponent(0.5)
        case "Line":
            a.color = c
            a.interiorColor = c
        default: a.color = c
        }
        annotationsChanged(on: page)
        undoManager?.registerUndo(withTarget: self) { v in v.setColor(old, of: a, on: page) }
        undoManager?.setActionName("Couleur")
    }

    // MARK: - Ajout / suppression avec annulation

    func insert(_ a: PDFAnnotation, on page: PDFPage, actionName: String) {
        page.addAnnotation(a)
        annotationsChanged(on: page)
        undoManager?.registerUndo(withTarget: self) { v in v.remove(a, from: page, actionName: actionName) }
        undoManager?.setActionName(actionName)
    }

    func remove(_ a: PDFAnnotation, from page: PDFPage, actionName: String) {
        if selectedAnnotation === a { select(nil) }
        page.removeAnnotation(a)
        annotationsChanged(on: page)
        undoManager?.registerUndo(withTarget: self) { v in v.insert(a, on: page, actionName: actionName) }
        undoManager?.setActionName(actionName)
    }

    private func registerBoundsUndo(_ a: PDFAnnotation, on page: PDFPage, restoreTo old: NSRect, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { v in
            let current = a.bounds
            AnnotationGeometry.setBounds(a, to: old)
            v.annotationsChanged(on: page)
            v.refreshOverlay()
            v.registerBoundsUndo(a, on: page, restoreTo: current, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }
}
