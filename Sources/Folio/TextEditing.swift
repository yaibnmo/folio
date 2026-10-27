import AppKit
import PDFKit

// MARK: - Mise en forme d'une zone de texte

struct TextFormat: Equatable {
    /// Dernière mise en forme choisie : reprise pour la zone suivante.
    static var last = TextFormat()

    var family = "Helvetica"
    var size: CGFloat = 14
    var bold = false
    var italic = false
    var color: NSColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)
    var alignment: NSTextAlignment = .left
    var fill: NSColor? = nil

    static let families: [String] = [
        "Helvetica", "Helvetica Neue", "Arial", "Avenir Next", "Verdana",
        "Times", "Georgia", "Courier", "Menlo", "Marker Felt", "Snell Roundhand",
    ].filter { NSFontManager.shared.availableFontFamilies.contains($0) }

    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]

    static let fills: [(name: String, color: NSColor?)] = [
        ("Sans fond", nil),
        ("Fond blanc", .white),
        ("Fond jaune", NSColor(srgbRed: 1, green: 0.96, blue: 0.62, alpha: 1)),
        ("Fond gris", NSColor(white: 0.92, alpha: 1)),
    ]

    func font(scale: CGFloat = 1) -> NSFont {
        let s = max(1, size * scale)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let fm = NSFontManager.shared
        if let f = fm.font(withFamily: family, traits: traits, weight: 5, size: s) { return f }
        if let f = fm.font(withFamily: family, traits: [], weight: 5, size: s) { return fm.convert(f, toHaveTrait: traits) }
        return .systemFont(ofSize: s)
    }

    static func from(_ a: PDFAnnotation) -> TextFormat {
        var t = TextFormat()
        if let f = a.font {
            t.size = f.pointSize
            let traits = NSFontManager.shared.traits(of: f)
            t.bold = traits.contains(.boldFontMask)
            t.italic = traits.contains(.italicFontMask)
            if let family = f.familyName { t.family = family }
        }
        t.color = a.fontColor ?? .black
        t.alignment = a.alignment
        t.fill = a.color.alphaComponent > 0.01 ? a.color : nil
        return t
    }

    func apply(to a: PDFAnnotation) {
        a.font = font()
        a.fontColor = color
        a.alignment = alignment
        a.color = fill ?? .clear
    }
}

struct TextEditSession {
    let annotation: PDFAnnotation
    let page: PDFPage
    let isNew: Bool
    let oldText: String
    let oldFormat: TextFormat
    let oldBounds: NSRect
    var shape: ShapeAnnotation? = nil
}

// MARK: - Barre de mise en forme flottante

final class TextFormatBar: NSVisualEffectView {
    var onChange: ((TextFormat) -> Void)?
    private(set) var format = TextFormat()

    private let familyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let styleControl = NSSegmentedControl(frame: .zero)
    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
    private let alignControl = NSSegmentedControl(frame: .zero)
    private let fillPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        for p in [familyPopup, sizePopup, fillPopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.target = self
            p.action = #selector(changed(_:))
        }
        for name in TextFormat.families {
            familyPopup.addItem(withTitle: name)
            familyPopup.lastItem?.attributedTitle = NSAttributedString(
                string: name, attributes: [.font: NSFont(name: name, size: 12) ?? NSFont.systemFont(ofSize: 12)])
        }
        sizePopup.addItems(withTitles: TextFormat.sizes.map { "\(Int($0)) pt" })
        fillPopup.addItems(withTitles: TextFormat.fills.map { $0.name })

        styleControl.segmentCount = 2
        styleControl.trackingMode = .selectAny
        styleControl.controlSize = .small
        for (i, (symbol, tip)) in [("bold", "Gras"), ("italic", "Italique")].enumerated() {
            styleControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            styleControl.setToolTip(tip, forSegment: i)
            styleControl.setWidth(26, forSegment: i)
        }
        styleControl.target = self
        styleControl.action = #selector(changed(_:))

        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }
        colorWell.toolTip = "Couleur du texte"
        colorWell.target = self
        colorWell.action = #selector(changed(_:))

        alignControl.segmentCount = 3
        alignControl.trackingMode = .selectOne
        alignControl.controlSize = .small
        for (i, s) in ["text.alignleft", "text.aligncenter", "text.alignright"].enumerated() {
            alignControl.setImage(NSImage(systemSymbolName: s, accessibilityDescription: nil), forSegment: i)
            alignControl.setWidth(26, forSegment: i)
        }
        alignControl.target = self
        alignControl.action = #selector(changed(_:))

        let stack = NSStackView(views: [familyPopup, sizePopup, styleControl, colorWell, alignControl, fillPopup])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            familyPopup.widthAnchor.constraint(equalToConstant: 130),
            colorWell.widthAnchor.constraint(equalToConstant: 34),
            colorWell.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    // La barre ne transmet pas les clics à la page.
    override func mouseDown(with event: NSEvent) {}

    func set(_ f: TextFormat) {
        format = f
        if let i = TextFormat.families.firstIndex(of: f.family) {
            familyPopup.selectItem(at: i)
        } else {
            familyPopup.selectItem(at: -1)
            familyPopup.setTitle(f.family)
        }
        let nearest = TextFormat.sizes.enumerated().min { abs($0.element - f.size) < abs($1.element - f.size) }?.offset ?? 5
        sizePopup.selectItem(at: nearest)
        styleControl.setSelected(f.bold, forSegment: 0)
        styleControl.setSelected(f.italic, forSegment: 1)
        colorWell.color = f.color
        alignControl.selectedSegment = f.alignment == .center ? 1 : (f.alignment == .right ? 2 : 0)
        let fillIndex = TextFormat.fills.firstIndex { entry in
            guard let a = entry.color, let b = f.fill else { return entry.color == nil && f.fill == nil }
            return a.usingColorSpace(.sRGB) == b.usingColorSpace(.sRGB)
        } ?? 0
        fillPopup.selectItem(at: fillIndex)
    }

    @objc private func changed(_ sender: Any?) {
        var f = format
        if let title = familyPopup.titleOfSelectedItem, TextFormat.families.contains(title) { f.family = title }
        let si = sizePopup.indexOfSelectedItem
        if TextFormat.sizes.indices.contains(si) { f.size = TextFormat.sizes[si] }
        f.bold = styleControl.isSelected(forSegment: 0)
        f.italic = styleControl.isSelected(forSegment: 1)
        f.color = colorWell.color.usingColorSpace(.sRGB) ?? colorWell.color
        f.alignment = [NSTextAlignment.left, .center, .right][max(0, alignControl.selectedSegment)]
        let fi = fillPopup.indexOfSelectedItem
        f.fill = TextFormat.fills.indices.contains(fi) ? TextFormat.fills[fi].color : nil
        format = f
        TextFormat.last = f
        onChange?(f)
    }
}

// MARK: - Édition directe sur la page

/// Délégué séparé (évite d'interférer avec l'édition des formulaires gérée par PDFView).
final class TextEditorDelegate: NSObject, NSTextViewDelegate {
    weak var view: FolioPDFView?

    func textDidChange(_ notification: Notification) {
        view?.layoutTextEditor()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            view?.endTextEditing()
            return true
        }
        return false
    }
}

extension FolioPDFView {
    static let textPadX: CGFloat = 7
    static let textPadY: CGFloat = 4
    /// Marge réelle utilisée par PDFKit pour dessiner le texte (pour que l'édition colle au rendu final).
    static let renderInsetX: CGFloat = 2.5
    static let renderInsetY: CGFloat = 1

    var isEditingText: Bool { textEditing != nil }

    /// Crée une zone de texte au point cliqué et ouvre l'édition directe.
    func addFreeText(on page: PDFPage, at p: NSPoint) {
        let a = PDFAnnotation(bounds: NSRect(x: p.x, y: p.y - 22, width: 40, height: 22), forType: .freeText, withProperties: nil)
        a.border = AnnotationFactory.border(0)
        a.contents = ""
        TextFormat.last.apply(to: a)
        host?.pdfViewWantsTool(.select)
        beginTextEditing(a, on: page, isNew: true)
    }

    func beginTextEditing(_ a: PDFAnnotation, on page: PDFPage, isNew: Bool) {
        endTextEditing()
        select(nil)
        currentTextFormat = TextFormat.from(a)
        textEditing = TextEditSession(annotation: a, page: page, isNew: isNew, oldText: a.contents ?? "",
                                      oldFormat: currentTextFormat, oldBounds: a.bounds)
        if !isNew {
            a.shouldDisplay = false
            repaint(page)
        }
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.focusRingType = .none
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.string = a.contents ?? ""
        textDelegate.view = self
        tv.delegate = textDelegate
        textEditor = tv
        addSubview(tv)
        styleTextEditor()
        layoutTextEditor()
        showFormatBar()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    /// Écrire directement dans une forme (rectangle, ellipse).
    func beginShapeTextEditing(_ shape: ShapeAnnotation, on page: PDFPage) {
        endTextEditing()
        select(nil)
        currentTextFormat = shape.model.text.isEmpty ? {
            var f = TextFormat.last
            f.alignment = .center
            f.fill = nil
            return f
        }() : shape.model.textStyle.format
        textEditing = TextEditSession(annotation: shape, page: page, isNew: false, oldText: shape.model.text,
                                      oldFormat: currentTextFormat, oldBounds: shape.bounds, shape: shape)
        shape.hidesText = true
        // Redessin forcé : sans cela PDFKit continue d'afficher l'ancien texte.
        shape.shouldDisplay = false
        annotationsChanged(on: page)
        shape.shouldDisplay = true
        repaint(page)
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.focusRingType = .none
        tv.wantsLayer = true
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        tv.string = shape.model.text
        textDelegate.view = self
        tv.delegate = textDelegate
        textEditor = tv
        addSubview(tv)
        styleTextEditor()
        layoutTextEditor()
        showFormatBar()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    func styleTextEditor() {
        guard let tv = textEditor else { return }
        let f = currentTextFormat
        let s = scaleFactor
        tv.font = f.font(scale: s)
        tv.textColor = f.color
        tv.alignment = f.alignment
        tv.insertionPointColor = f.color
        tv.drawsBackground = f.fill != nil
        tv.backgroundColor = f.fill ?? .clear
        tv.textContainerInset = NSSize(width: Self.renderInsetX * s, height: Self.renderInsetY * s)
        if textEditing?.shape != nil {
            tv.drawsBackground = false
            tv.textContainerInset = .zero
        }
    }

    func layoutTextEditor() {
        guard let tv = textEditor, let ed = textEditing,
              let container = tv.textContainer, let lm = tv.layoutManager else { return }
        let s = scaleFactor
        if let shape = ed.shape {
            // Texte dans une forme : cadre fixe, texte centré verticalement.
            let inner = ShapeGeometry.textRect(shape.bounds, shape.model.style, kind: shape.model.kind)
            let frame = convert(inner, from: ed.page)
            container.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: container)
            let used = lm.usedRect(for: container).height
            tv.textContainerInset = NSSize(width: 0, height: max(0, (frame.height - used) / 2))
            tv.frame = frame
            positionFormatBar(around: convert(shape.bounds, from: ed.page))
            return
        }
        let font = currentTextFormat.font()
        // Mesure du texte (même calcul que le rendu final), largeur max 420 pt.
        let lineHeight = lm.defaultLineHeight(for: font)
        let measured = (tv.string.isEmpty ? " " : tv.string) as NSString
        let r = measured.boundingRect(with: NSSize(width: 420, height: 100_000),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let extraLine: CGFloat = tv.string.hasSuffix("\n") ? lineHeight : 0
        let textW = max(ceil(r.width), 24)
        let textH = max(ceil(r.height) + extraLine, lineHeight)
        let w = ceil(textW) + 2 * Self.textPadX
        container.containerSize = NSSize(width: (w - 2 * Self.renderInsetX) * s, height: .greatestFiniteMagnitude)
        let h = ceil(textH) + 2 * Self.textPadY
        let old = ed.annotation.bounds
        let b = NSRect(x: old.minX, y: old.maxY - h, width: w, height: h)
        ed.annotation.bounds = b
        tv.frame = convert(b, from: ed.page)
        positionFormatBar(around: tv.frame)
    }

    func endTextEditing() {
        guard let tv = textEditor, let ed = textEditing else { return }
        layoutTextEditor()
        let text = tv.string
        let finalBounds = ed.annotation.bounds
        tv.delegate = nil
        tv.removeFromSuperview()
        textEditor = nil
        textEditing = nil
        formatBar.removeFromSuperview()
        if let shape = ed.shape {
            shape.hidesText = false
            shape.shouldDisplay = false
            annotationsChanged(on: ed.page)
            shape.shouldDisplay = true
            var m = shape.model
            m.text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
            m.textStyle = ShapeText(currentTextFormat)
            if m != shape.model {
                setShapeModel(shape, m, bounds: shape.bounds, on: ed.page, actionName: "Texte de la forme")
            } else {
                annotationsChanged(on: ed.page)
            }
            select(shape)
            window?.makeFirstResponder(self)
            return
        }
        let a = ed.annotation
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ed.isNew {
            guard !isEmpty else { return }
            a.contents = text
            currentTextFormat.apply(to: a)
            insert(a, on: ed.page, actionName: "Zone de texte")
            select(a)
        } else {
            a.bounds = ed.oldBounds
            a.shouldDisplay = true
            if isEmpty {
                remove(a, from: ed.page, actionName: "Supprimer le texte")
            } else {
                setText(text, format: currentTextFormat, bounds: finalBounds, of: a, on: ed.page)
                select(a)
            }
            annotationsChanged(on: ed.page)
        }
        window?.makeFirstResponder(self)
    }

    /// Modifie texte + mise en forme + cadre d'une zone de texte (annulable).
    func setText(_ text: String, format: TextFormat, bounds: NSRect, of a: PDFAnnotation, on page: PDFPage) {
        let oldText = a.contents ?? ""
        let oldFormat = TextFormat.from(a)
        let oldBounds = a.bounds
        a.contents = text
        format.apply(to: a)
        a.bounds = bounds
        annotationsChanged(on: page)
        refreshOverlay()
        undoManager?.registerUndo(withTarget: self) { v in
            v.setText(oldText, format: oldFormat, bounds: oldBounds, of: a, on: page)
        }
        undoManager?.setActionName("Modifier le texte")
    }

    // MARK: Barre de mise en forme

    func showFormatBar() {
        formatBar.onChange = { [weak self] f in self?.formatChanged(f) }
        formatBar.set(currentTextFormat)
        if formatBar.superview !== self || subviews.last !== formatBar {
            formatBar.removeFromSuperview()
            addSubview(formatBar)
        }
        formatBar.frame.size = formatBar.fittingSize
    }

    func positionFormatBar(around r: NSRect) {
        guard formatBar.superview === self else { return }
        let size = formatBar.fittingSize
        let gap: CGFloat = 8
        let x = min(max(8, r.minX), max(8, bounds.width - size.width - 8))
        var y: CGFloat
        if isFlipped {
            y = r.minY - gap - size.height
            if y < 8 { y = r.maxY + gap }
        } else {
            y = r.maxY + gap
            if y + size.height > bounds.height - 8 { y = r.minY - gap - size.height }
        }
        formatBar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Barre visible pendant l'édition, ou quand une zone de texte est sélectionnée.
    func updateFormatBarForSelection() {
        guard textEditor == nil else { return }
        if let a = selectedAnnotation, a.kind == "FreeText", let page = a.page {
            if formatBar.superview !== self {
                currentTextFormat = TextFormat.from(a)
                showFormatBar()
            }
            positionFormatBar(around: convert(a.bounds, from: page))
        } else if formatBar.superview != nil {
            formatBar.removeFromSuperview()
        }
    }

    private func formatChanged(_ f: TextFormat) {
        currentTextFormat = f
        if let tv = textEditor {
            styleTextEditor()
            layoutTextEditor()
            window?.makeFirstResponder(tv)
        } else if let a = selectedAnnotation, a.kind == "FreeText", let page = a.page {
            let text = a.contents ?? ""
            let size = AnnotationFactory.fittingSize(text, font: f.font())
            let b = a.bounds
            setText(text, format: f, bounds: NSRect(x: b.minX, y: b.maxY - size.height, width: size.width, height: size.height),
                    of: a, on: page)
            positionFormatBar(around: convert(a.bounds, from: page))
        }
    }

}
