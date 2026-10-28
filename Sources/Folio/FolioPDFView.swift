import AppKit
import PDFKit

protocol FolioPDFViewHost: AnyObject {
    func pdfViewDidModify(pageIndex: Int)
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
    var showsBox = true
    var cornerHandles = false
    var endpoints: [NSPoint] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func handle(at c: NSPoint) {
        let r = NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        if !endpoints.isEmpty {
            endpoints.forEach { handle(at: $0) }
            return
        }
        if cornerHandles {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 6, dy: 6))
            path.lineWidth = 1
            let dash: [CGFloat] = [4, 3]
            path.setLineDash(dash, count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            let r = bounds.insetBy(dx: 6, dy: 6)
            for c in [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)] {
                handle(at: c)
            }
            return
        }
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
            refreshOverlay()
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
    let shapeBar = ShapeFormatBar()
    private var shiftDown = false
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
        case endpoint(ShapeAnnotation, PDFPage, index: Int, oldModel: ShapeModel, oldBounds: NSRect, original: [CGPoint])
        case corner(ShapeAnnotation, PDFPage, fixed: NSPoint, original: NSRect)
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

    /// Le premier clic agit même si la fenêtre n'était pas au premier plan.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        updateShapeBar()
        guard let a = selectedAnnotation, let page = a.page else {
            overlay.isHidden = true
            return
        }
        if let shape = a as? ShapeAnnotation {
            if shape.isArrow {
                overlay.frame = convert(a.bounds, from: page).insetBy(dx: -8, dy: -8)
                let pts = shape.absolutePoints
                overlay.endpoints = [pts.first, pts.last].compactMap { $0 }.map { overlay.convert(convert($0, from: page), from: self) }
                overlay.cornerHandles = false
            } else {
                overlay.frame = convert(a.bounds, from: page).insetBy(dx: -6, dy: -6)
                overlay.endpoints = []
                overlay.cornerHandles = true
            }
            overlay.isHidden = false
            overlay.needsDisplay = true
            return
        }
        overlay.endpoints = []
        overlay.cornerHandles = false
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
        let tolerance = 6 / max(scaleFactor, 0.1)
        for a in page.annotations.reversed() where a.isUserSelectable {
            if let shape = a as? ShapeAnnotation {
                if shape.hitTest(p, tolerance: tolerance) { return shape }
                continue
            }
            if a.bounds.insetBy(dx: -3, dy: -3).contains(p) { return a }
        }
        return nil
    }

    /// Poignées des formes : extrémité de flèche (index 0/1) ou coin (point opposé fixe).
    private func shapeHandle(at vp: NSPoint, on page: PDFPage) -> Drag? {
        guard let shape = selectedAnnotation as? ShapeAnnotation, shape.page == page else { return nil }
        func near(_ p: NSPoint) -> Bool {
            let v = convert(p, from: page)
            return hypot(v.x - vp.x, v.y - vp.y) < 10
        }
        if shape.isArrow {
            let pts = shape.absolutePoints
            guard let first = pts.first, let last = pts.last else { return nil }
            if near(last) { return .endpoint(shape, page, index: 1, oldModel: shape.model, oldBounds: shape.bounds, original: pts) }
            if near(first) { return .endpoint(shape, page, index: 0, oldModel: shape.model, oldBounds: shape.bounds, original: pts) }
            return nil
        }
        let b = shape.bounds
        let corners = [NSPoint(x: b.minX, y: b.minY), NSPoint(x: b.maxX, y: b.minY), NSPoint(x: b.minX, y: b.maxY), NSPoint(x: b.maxX, y: b.maxY)]
        for (i, c) in corners.enumerated() where near(c) {
            return .corner(shape, page, fixed: corners[3 - i], original: b)
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
        DebugLog.write("mouseDown tool=\(tool) clicks=\(event.clickCount) page=\(document?.index(for: page) ?? -1) pt=\(Int(pp.x)),\(Int(pp.y)) sous le pointeur=\(page.annotations.filter { $0.bounds.contains(pp) }.map { "\($0.kind)/\(type(of: $0)) \(Int($0.bounds.minX)),\(Int($0.bounds.minY)) \(Int($0.bounds.width))x\(Int($0.bounds.height))" }) hit=\(hitAnnotation(on: page, at: pp).map { $0.kind } ?? "aucun") editeur=\(textEditor != nil)")
        if textEditor != nil {
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)

        let drawingTools: [Tool] = [.select, .ink, .rect, .oval, .arrow]
        if !drawingTools.contains(tool), let a = hitAnnotation(on: page, at: pp), a.isMovable {
            host?.pdfViewWantsTool(.select)
            select(a)
            if event.clickCount == 2 { editContents(of: a); return }
            drag = .move(a, page, start: pp, original: a.bounds)
            NSCursor.closedHand.set()
            return
        }

        switch tool {
        case .select:
            if let handle = shapeHandle(at: vp, on: page) {
                drag = handle
                return
            }
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
        shiftDown = event.modifierFlags.contains(.shift)
        switch drag {
        case let .endpoint(shape, page, index, _, _, original):
            var p = convert(vp, to: page)
            var pts = original
            if shape.model.style.route == .curve && pts.count > 2 {
                pts = ShapeGeometry.remap(original, moving: index, to: p)
            } else {
                if shiftDown, let other = index == 0 ? original.last : original.first { p = ShapeGeometry.snap(p, from: other) }
                if index == 0 { pts[0] = p } else { pts[pts.count - 1] = p }
            }
            shape.setAbsolutePoints(pts)
            repaint(page)
            refreshOverlay()

        case let .corner(shape, page, fixed, _):
            let p = convert(vp, to: page)
            let r = NSRect(x: min(p.x, fixed.x), y: min(p.y, fixed.y), width: max(abs(p.x - fixed.x), 10), height: max(abs(p.y - fixed.y), 10))
            shape.bounds = r
            repaint(page)
            refreshOverlay()

        case .none:
            super.mouseDragged(with: event)

        case let .move(a, page, start, original):
            let p = convert(vp, to: page)
            var r = original
            r.origin.x += p.x - start.x
            r.origin.y += p.y - start.y
            a.bounds = r
            repaint(page)
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
            repaint(page)
            refreshOverlay()

        case .shape(let page, var points, let preview):
            let p = convert(vp, to: page)
            let freehand = tool == .ink || (tool == .arrow && ShapeStyle.lastArrow.route == .curve)
            if freehand { points.append(p) } else { points = [points[0], p] }
            let next = makeShape(points)
            if let current = preview as? ShapeAnnotation, let updated = next as? ShapeAnnotation {
                // Aperçu mis à jour sur place (évite les traces laissées par le cache de PDFKit)
                current.model = updated.model
                current.bounds = updated.bounds
                current.shouldDisplay = true
                repaint(page)
                drag = .shape(page, points: points, preview: current)
            } else {
                if let preview { discard(preview, from: page) }
                if let next { page.addAnnotation(next) }
                repaint(page)
                drag = .shape(page, points: points, preview: next)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case let .endpoint(shape, page, _, oldModel, oldBounds, _):
            let newModel = shape.model, newBounds = shape.bounds
            if newModel != oldModel || newBounds != oldBounds {
                shape.model = oldModel
                shape.bounds = oldBounds
                setShapeModel(shape, newModel, bounds: newBounds, on: page, actionName: "Modifier la flèche")
            }

        case let .corner(shape, page, _, original):
            if shape.bounds != original { registerBoundsUndo(shape, on: page, restoreTo: original, actionName: "Redimensionner") }

        case .none:
            super.mouseUp(with: event)
            if tool.isMarkup { applyMarkup() }

        case let .move(a, page, _, original):
            if a.bounds != original { registerBoundsUndo(a, on: page, restoreTo: original, actionName: "Déplacer") }

        case let .resize(a, page, original):
            if a.bounds != original { registerBoundsUndo(a, on: page, restoreTo: original, actionName: "Redimensionner") }

        case let .shape(page, points, preview):
            if let preview { discard(preview, from: page) }
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
            if shapeHandle(at: vp, on: page) != nil {
                NSCursor.crosshair.set()
                return
            }
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
        DebugLog.write("keyDown code=\(event.keyCode) sélection=\(selectedAnnotation?.kind ?? "aucune")")
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
        case .rect, .oval:
            var end = last
            if shiftDown {
                let side = max(abs(last.x - first.x), abs(last.y - first.y))
                end = NSPoint(x: first.x + (last.x >= first.x ? side : -side), y: first.y + (last.y >= first.y ? side : -side))
            }
            let r = NSRect(x: min(first.x, end.x), y: min(first.y, end.y), width: abs(end.x - first.x), height: abs(end.y - first.y))
            guard r.width > 3, r.height > 3 else { return nil }
            let style = ShapeStyle.lastShape
            let model = ShapeModel(kind: tool == .rect ? .rect : .ellipse, style: style)
            return ShapeAnnotation(model: model, bounds: r.insetBy(dx: -(style.width / 2 + 1), dy: -(style.width / 2 + 1)))
        case .arrow:
            let style = ShapeStyle.lastArrow
            var pts: [CGPoint]
            if style.route == .curve {
                pts = ShapeGeometry.simplify(points, tolerance: 1.5)
            } else {
                pts = [first, shiftDown ? ShapeGeometry.snap(last, from: first) : last]
            }
            guard pts.count >= 2, let a = pts.first, let b = pts.last, hypot(b.x - a.x, b.y - a.y) > 6 else { return nil }
            let shape = ShapeAnnotation(model: ShapeModel(kind: .arrow, style: style), bounds: .zero)
            shape.setAbsolutePoints(pts)
            return shape
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
            if a.kind != "Stamp" || a is ShapeAnnotation {
                menu.addItem(MenuAction.submenu(a is ShapeAnnotation ? "Couleur du contour" : "Couleur", colors))
            }
            if let shape = a as? ShapeAnnotation, !shape.isArrow, let page = shape.page {
                let fills = NSMenu()
                fills.addItem(MenuAction.item("Aucun") { [weak self] in
                    var m = shape.model
                    m.style.fill = nil
                    self?.setShapeModel(shape, m, on: page, actionName: "Fond")
                })
                for entry in Palette.colors {
                    fills.addItem(MenuAction.item(entry.name, image: Palette.swatch(entry.color)) { [weak self] in
                        var m = shape.model
                        m.style.fill = RGBA(entry.color)
                        self?.setShapeModel(shape, m, on: page, actionName: "Fond")
                    })
                }
                menu.addItem(MenuAction.submenu("Couleur de fond", fills))
                menu.addItem(MenuAction.item(shape.model.text.isEmpty ? "Écrire dans la forme" : "Modifier le texte de la forme") { [weak self] in
                    self?.beginShapeTextEditing(shape, on: page)
                })
            }
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
        if let shape = a as? ShapeAnnotation {
            if !shape.isArrow, let page = shape.page { beginShapeTextEditing(shape, on: page) }
            return
        }
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
        if let shape = a as? ShapeAnnotation {
            var m = shape.model
            m.style.stroke = RGBA(c)
            setShapeModel(shape, m, on: page, actionName: "Couleur du contour")
            return
        }
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

    /// Retire une annotation temporaire sans laisser de trace à l'écran.
    func discard(_ a: PDFAnnotation, from page: PDFPage) {
        a.shouldDisplay = false
        annotationsChanged(on: page)
        page.removeAnnotation(a)
        repaint(page)
    }

    /// Force le rafraîchissement de la page (PDFKit garde parfois un rendu en cache).
    func repaint(_ page: PDFPage) {
        annotationsChanged(on: page)
        if let i = document?.index(for: page) { host?.pdfViewDidModify(pageIndex: i) }
        if let dv = documentView { dv.setNeedsDisplay(dv.bounds) }
        for v in documentView?.subviews ?? [] { v.setNeedsDisplay(v.bounds) }
        setNeedsDisplay(bounds)
    }

    // MARK: - Formes

    /// Applique un nouveau modèle à une forme (annulable).
    func setShapeModel(_ shape: ShapeAnnotation, _ m: ShapeModel, bounds: NSRect? = nil, on page: PDFPage, actionName: String = "Modifier la forme") {
        let oldModel = shape.model, oldBounds = shape.bounds
        if let bounds {
            shape.model = m
            shape.bounds = bounds
        } else if m.kind == .arrow {
            let abs = m.points.map { CGPoint(x: $0.x + oldBounds.minX, y: $0.y + oldBounds.minY) }
            shape.model = m
            shape.setAbsolutePoints(abs)
        } else {
            shape.model = m
        }
        shape.shouldDisplay = false
        annotationsChanged(on: page)
        shape.shouldDisplay = true
        repaint(page)
        refreshOverlay()
        undoManager?.registerUndo(withTarget: self) { v in
            v.setShapeModel(shape, oldModel, bounds: oldBounds, on: page, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Barre « forme » : quand une forme est sélectionnée, ou quand un outil forme est actif.
    func updateShapeBar() {
        let selectedShape = selectedAnnotation as? ShapeAnnotation
        let toolKind: ShapeKind? = tool == .rect ? .rect : (tool == .oval ? .ellipse : (tool == .arrow ? .arrow : nil))
        guard textEditor == nil, selectedShape != nil || (toolKind != nil && selectedAnnotation == nil) else {
            if shapeBar.superview != nil { shapeBar.removeFromSuperview() }
            return
        }
        shapeBar.onChange = { [weak self] style in self?.shapeStyleChanged(style) }
        shapeBar.onEditText = { [weak self] in
            guard let self, let s = self.selectedAnnotation as? ShapeAnnotation, let page = s.page else { return }
            self.beginShapeTextEditing(s, on: page)
        }
        if let shape = selectedShape, let page = shape.page {
            shapeBar.configure(shape.model.style, kind: shape.model.kind, canEditText: true)
            if shapeBar.superview !== self || subviews.last !== shapeBar {
                shapeBar.removeFromSuperview()
                addSubview(shapeBar)
            }
            positionBar(shapeBar, around: convert(shape.bounds, from: page))
        } else if let kind = toolKind {
            shapeBar.configure(kind == .arrow ? ShapeStyle.lastArrow : ShapeStyle.lastShape, kind: kind, canEditText: false)
            if shapeBar.superview !== self {
                addSubview(shapeBar)
            }
            positionBar(shapeBar, around: nil)
        }
    }

    private func shapeStyleChanged(_ style: ShapeStyle) {
        if let shape = selectedAnnotation as? ShapeAnnotation, let page = shape.page {
            var m = shape.model
            m.style = style
            setShapeModel(shape, m, on: page)
            if shape.isArrow { ShapeStyle.lastArrow = style } else { ShapeStyle.lastShape = style }
        } else if tool == .arrow {
            ShapeStyle.lastArrow = style
        } else {
            ShapeStyle.lastShape = style
        }
        host?.pdfViewSelectionChanged(selectedAnnotation)
    }

    /// Place une barre flottante au-dessus d'un rectangle (ou en haut de la vue si aucun).
    func positionBar(_ bar: NSView, around r: NSRect?) {
        let size = bar.fittingSize
        let gap: CGFloat = 8
        guard let r else {
            let x = max(8, (bounds.width - size.width) / 2)
            let y = isFlipped ? 10 : bounds.height - size.height - 10
            bar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            return
        }
        let x = min(max(8, r.minX), max(8, bounds.width - size.width - 8))
        var y: CGFloat
        if isFlipped {
            y = r.minY - gap - size.height
            if y < 8 { y = r.maxY + gap }
        } else {
            y = r.maxY + gap
            if y + size.height > bounds.height - 8 { y = r.minY - gap - size.height }
        }
        bar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Ajout / suppression avec annulation

    func insert(_ a: PDFAnnotation, on page: PDFPage, actionName: String) {
        a.shouldDisplay = true
        page.addAnnotation(a)
        repaint(page)
        undoManager?.registerUndo(withTarget: self) { v in v.remove(a, from: page, actionName: actionName) }
        undoManager?.setActionName(actionName)
    }

    func remove(_ a: PDFAnnotation, from page: PDFPage, actionName: String) {
        if selectedAnnotation === a { select(nil) }
        let before = page.annotations.count
        // Contournement PDFKit : masquer avant de retirer, sinon l'ancien rendu reste affiché.
        a.shouldDisplay = false
        annotationsChanged(on: page)
        page.removeAnnotation(a)
        repaint(page)
        DebugLog.write("remove \(a.kind)/\(type(of: a)) : \(before) -> \(page.annotations.count) annotations ; encore présente=\(page.annotations.contains { $0 === a })")
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
