import AppKit
import PDFKit

// MARK: - Modèle

struct RGBA: Codable, Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? NSColor.black
        r = s.redComponent; g = s.greenComponent; b = s.blueComponent; a = s.alphaComponent
    }

    var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum DashStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted
    var title: String {
        switch self {
        case .solid: return "Continu"
        case .dashed: return "Tirets"
        case .dotted: return "Pointillés"
        }
    }
}

enum ArrowHead: String, Codable, CaseIterable {
    case none, open, closed, circle, square, diamond, bar
    var title: String {
        switch self {
        case .none: return "Aucune"
        case .open: return "Flèche"
        case .closed: return "Flèche pleine"
        case .circle: return "Rond"
        case .square: return "Carré"
        case .diamond: return "Losange"
        case .bar: return "Barre"
        }
    }
}

enum ArrowRoute: String, Codable, CaseIterable {
    case straight, elbow, doubleElbow, curve
    var title: String {
        switch self {
        case .straight: return "Droite"
        case .elbow: return "Coudée (1 angle)"
        case .doubleElbow: return "Coudée (2 angles)"
        case .curve: return "Courbe à main levée"
        }
    }
}

enum ShapeKind: String, Codable {
    case rect, ellipse, arrow
}

struct ShapeStyle: Codable, Equatable {
    var stroke = RGBA(0.9, 0.15, 0.15)
    var width: CGFloat = 2
    var dash: DashStyle = .solid
    var fill: RGBA? = nil
    var rounded = false
    var startHead: ArrowHead = .none
    var endHead: ArrowHead = .closed
    var route: ArrowRoute = .straight

    /// Derniers réglages utilisés (repris pour la forme suivante, mémorisés entre les sessions).
    static var lastShape: ShapeStyle = load("lastShapeStyle") ?? ShapeStyle() {
        didSet { save(lastShape, "lastShapeStyle") }
    }
    static var lastArrow: ShapeStyle = load("lastArrowStyle") ?? ShapeStyle() {
        didSet { save(lastArrow, "lastArrowStyle") }
    }

    private static func load(_ key: String) -> ShapeStyle? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShapeStyle.self, from: data)
    }

    private static func save(_ s: ShapeStyle, _ key: String) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Mise en forme du texte écrit dans une forme (version enregistrable de TextFormat).
struct ShapeText: Codable, Equatable {
    var family = "Helvetica"
    var size: CGFloat = 14
    var bold = false
    var italic = false
    var color = RGBA(0.05, 0.05, 0.1)
    var alignment = 1

    init() {}

    init(_ f: TextFormat) {
        family = f.family; size = f.size; bold = f.bold; italic = f.italic
        color = RGBA(f.color)
        alignment = f.alignment == .center ? 1 : (f.alignment == .right ? 2 : 0)
    }

    var format: TextFormat {
        var f = TextFormat()
        f.family = family; f.size = size; f.bold = bold; f.italic = italic
        f.color = color.color
        f.alignment = alignment == 1 ? .center : (alignment == 2 ? .right : .left)
        f.fill = nil
        return f
    }
}

struct ShapeModel: Codable, Equatable {
    var kind: ShapeKind
    /// Flèches : points de contrôle, relatifs à l'origine du cadre de l'annotation.
    var points: [CGPoint] = []
    var style: ShapeStyle
    var text = ""
    var textStyle = ShapeText()
}

// MARK: - Géométrie et dessin

enum ShapeGeometry {
    static func headSize(_ width: CGFloat) -> CGFloat { max(9, width * 3.2) }

    static func padding(_ s: ShapeStyle) -> CGFloat { s.width / 2 + headSize(s.width) + 3 }

    /// Points du tracé (absolus) selon le type de flèche.
    static func route(_ pts: [CGPoint], _ r: ArrowRoute) -> [CGPoint] {
        guard pts.count >= 2, let a = pts.first, let b = pts.last else { return pts }
        let horizontal = abs(b.x - a.x) >= abs(b.y - a.y)
        switch r {
        case .straight:
            return [a, b]
        case .elbow:
            return horizontal ? [a, CGPoint(x: b.x, y: a.y), b] : [a, CGPoint(x: a.x, y: b.y), b]
        case .doubleElbow:
            if horizontal {
                let m = (a.x + b.x) / 2
                return [a, CGPoint(x: m, y: a.y), CGPoint(x: m, y: b.y), b]
            }
            let m = (a.y + b.y) / 2
            return [a, CGPoint(x: a.x, y: m), CGPoint(x: b.x, y: m), b]
        case .curve:
            return pts
        }
    }

    static func path(_ pts: [CGPoint], smooth: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if smooth && pts.count > 2 {
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
                p.curve(to: p2,
                        controlPoint1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                        controlPoint2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
        } else {
            for q in pts.dropFirst() { p.line(to: q) }
        }
        return p
    }

    /// Point situé à `distance` de l'extrémité, en remontant le tracé (pour orienter la pointe).
    static func pointBack(_ pts: [CGPoint], distance: CGFloat) -> CGPoint {
        guard var cur = pts.last else { return .zero }
        var remaining = distance
        for q in pts.dropLast().reversed() {
            let d = hypot(cur.x - q.x, cur.y - q.y)
            if d >= remaining, d > 0 {
                let t = remaining / d
                return CGPoint(x: cur.x + (q.x - cur.x) * t, y: cur.y + (q.y - cur.y) * t)
            }
            remaining -= d
            cur = q
        }
        return pts.first ?? .zero
    }

    /// Raccourcit le tracé à son extrémité (pour que le trait ne dépasse pas de la pointe).
    static func trimEnd(_ pts: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        guard pts.count >= 2, distance > 0 else { return pts }
        var out = pts
        var remaining = distance
        while out.count >= 2 {
            let a = out[out.count - 2], b = out[out.count - 1]
            let d = hypot(b.x - a.x, b.y - a.y)
            if d > remaining {
                let t = (d - remaining) / d
                out[out.count - 1] = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                return out
            }
            remaining -= d
            out.removeLast()
        }
        return out
    }

    static func applyDash(_ p: NSBezierPath, _ s: ShapeStyle) {
        p.lineWidth = s.width
        p.lineJoinStyle = .round
        switch s.dash {
        case .solid:
            p.lineCapStyle = .round
        case .dashed:
            p.lineCapStyle = .butt
            let pattern: [CGFloat] = [max(3, s.width * 3.5), max(2, s.width * 2.2)]
            p.setLineDash(pattern, count: 2, phase: 0)
        case .dotted:
            p.lineCapStyle = .round
            let pattern: [CGFloat] = [0.01, max(3, s.width * 2.4)]
            p.setLineDash(pattern, count: 2, phase: 0)
        }
    }

    static func closedRect(_ bounds: NSRect, _ s: ShapeStyle) -> NSRect {
        bounds.insetBy(dx: s.width / 2 + 1, dy: s.width / 2 + 1)
    }

    static func textRect(_ bounds: NSRect, _ s: ShapeStyle, kind: ShapeKind) -> NSRect {
        let r = closedRect(bounds, s)
        // Dans une ellipse, on reste dans le rectangle inscrit.
        let inset: CGFloat = kind == .ellipse ? 0.146 : 0
        return r.insetBy(dx: r.width * inset + 6 + s.width / 2, dy: r.height * inset + 4 + s.width / 2)
    }

    static func drawHead(_ head: ArrowHead, tip: CGPoint, from back: CGPoint, style s: ShapeStyle) {
        guard head != .none else { return }
        let dx = tip.x - back.x, dy = tip.y - back.y
        let len = max(hypot(dx, dy), 0.001)
        let u = CGPoint(x: dx / len, y: dy / len)
        let n = CGPoint(x: -u.y, y: u.x)
        let h = headSize(s.width)
        func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + u.x * along + n.x * side, y: tip.y + u.y * along + n.y * side)
        }
        s.stroke.color.setStroke()
        s.stroke.color.setFill()
        let p = NSBezierPath()
        p.lineWidth = s.width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        switch head {
        case .none:
            return
        case .open:
            p.move(to: pt(-h, h * 0.55)); p.line(to: tip); p.line(to: pt(-h, -h * 0.55))
            p.stroke()
        case .closed:
            p.move(to: tip); p.line(to: pt(-h, h * 0.5)); p.line(to: pt(-h, -h * 0.5)); p.close()
            p.fill(); p.stroke()
        case .circle:
            let r = h * 0.38
            NSBezierPath(ovalIn: NSRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)).fill()
        case .square:
            let a = h * 0.32
            p.move(to: pt(a, a)); p.line(to: pt(a, -a)); p.line(to: pt(-a, -a)); p.line(to: pt(-a, a)); p.close()
            p.fill()
        case .diamond:
            p.move(to: tip); p.line(to: pt(-h * 0.5, h * 0.36)); p.line(to: pt(-h, 0)); p.line(to: pt(-h * 0.5, -h * 0.36)); p.close()
            p.fill()
        case .bar:
            p.move(to: pt(0, h * 0.55)); p.line(to: pt(0, -h * 0.55))
            p.stroke()
        }
    }

    /// Distance de recul du trait selon la pointe (évite que le trait dépasse).
    static func trim(for head: ArrowHead, _ s: ShapeStyle) -> CGFloat {
        let h = headSize(s.width)
        switch head {
        case .closed: return h * 0.7
        case .diamond: return h * 0.8
        case .open, .none, .circle, .square, .bar: return s.width * 0.5
        }
    }

    static func draw(_ m: ShapeModel, bounds: NSRect, hideText: Bool = false) {
        let s = m.style
        switch m.kind {
        case .rect, .ellipse:
            let r = closedRect(bounds, s)
            let path: NSBezierPath
            if m.kind == .ellipse {
                path = NSBezierPath(ovalIn: r)
            } else if s.rounded {
                let radius = min(14, r.width / 4, r.height / 4)
                path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            } else {
                path = NSBezierPath(rect: r)
            }
            if let fill = s.fill {
                fill.color.setFill()
                path.fill()
            }
            if s.width > 0 {
                applyDash(path, s)
                s.stroke.color.setStroke()
                path.stroke()
            }
            if !hideText && !m.text.isEmpty {
                drawText(m, in: textRect(bounds, s, kind: m.kind))
            }
        case .arrow:
            let abs = m.points.map { CGPoint(x: $0.x + bounds.minX, y: $0.y + bounds.minY) }
            var pts = route(abs, s.route)
            guard pts.count >= 2 else { return }
            let h = headSize(s.width)
            let endTip = pts[pts.count - 1], startTip = pts[0]
            let endBack = pointBack(pts, distance: h)
            let startBack = pointBack(Array(pts.reversed()), distance: h)
            pts = trimEnd(pts, by: trim(for: s.endHead, s))
            pts = Array(trimEnd(Array(pts.reversed()), by: trim(for: s.startHead, s)).reversed())
            let line = path(pts, smooth: s.route == .curve)
            applyDash(line, s)
            s.stroke.color.setStroke()
            line.stroke()
            drawHead(s.endHead, tip: endTip, from: endBack, style: s)
            drawHead(s.startHead, tip: startTip, from: startBack, style: s)
        }
    }

    static func drawText(_ m: ShapeModel, in rect: NSRect) {
        let f = m.textStyle.format
        let para = NSMutableParagraphStyle()
        para.alignment = f.alignment
        let str = NSAttributedString(string: m.text, attributes: [.font: f.font(), .foregroundColor: f.color, .paragraphStyle: para])
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let h = min(rect.height, ceil(str.boundingRect(with: NSSize(width: rect.width, height: 100_000), options: opts).height))
        str.draw(with: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h), options: opts)
    }

    static func arrowBounds(_ abs: [CGPoint], _ s: ShapeStyle) -> NSRect {
        let pts = route(abs, s.route)
        guard let f = pts.first else { return .zero }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = padding(s) + (s.route == .curve ? 6 : 0)
        return NSRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Simplifie un tracé à main levée (Ramer–Douglas–Peucker).
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat = 1.5) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0, index = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(pts[i], toSegment: pts[0], pts[pts.count - 1])
            if d > maxD { maxD = d; index = i }
        }
        if maxD <= tolerance { return [pts[0], pts[pts.count - 1]] }
        let left = simplify(Array(pts[0...index]), tolerance: tolerance)
        let right = simplify(Array(pts[index...]), tolerance: tolerance)
        return Array(left.dropLast()) + right
    }

    /// Bloque l'angle par pas de 45° (touche ⇧).
    static func snap(_ p: CGPoint, from o: CGPoint) -> CGPoint {
        let len = hypot(p.x - o.x, p.y - o.y)
        let step = CGFloat.pi / 4
        let angle = (atan2(p.y - o.y, p.x - o.x) / step).rounded() * step
        return CGPoint(x: o.x + len * cos(angle), y: o.y + len * sin(angle))
    }

    /// Déplace une extrémité d'une courbe en entraînant toute la courbe (similitude).
    static func remap(_ pts: [CGPoint], moving index: Int, to p: CGPoint) -> [CGPoint] {
        guard let first = pts.first, let last = pts.last else { return pts }
        let fixed = index == 0 ? last : first
        let old = index == 0 ? first : last
        let ox = old.x - fixed.x, oy = old.y - fixed.y
        let nx = p.x - fixed.x, ny = p.y - fixed.y
        let d = ox * ox + oy * oy
        guard d > 0.01 else { return pts }
        let kr = (nx * ox + ny * oy) / d, ki = (ny * ox - nx * oy) / d
        return pts.map { q in
            let x = q.x - fixed.x, y = q.y - fixed.y
            return CGPoint(x: fixed.x + x * kr - y * ki, y: fixed.y + x * ki + y * kr)
        }
    }
}

// MARK: - Annotation

/// Forme ou flèche dessinée par Folio. Enregistrée dans le PDF comme un tampon dont l'apparence
/// est le dessin (lisible partout), avec ses réglages dans une clé /FolioShape (modifiable à la réouverture).
final class ShapeAnnotation: PDFAnnotation {
    static let modelKey = PDFAnnotationKey(rawValue: "/FolioShape")

    var model = ShapeModel(kind: .rect, style: ShapeStyle()) {
        didSet { persist() }
    }
    var hidesText = false

    convenience init(model: ShapeModel, bounds: NSRect) {
        self.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.model = model
        persist()  // les observateurs ne sont pas appelés pendant l'initialisation
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(model), let json = String(data: data, encoding: .utf8) {
            _ = setValue(json, forAnnotationKey: Self.modelKey)
        }
    }

    static func decode(from a: PDFAnnotation) -> ShapeModel? {
        guard let json = a.value(forAnnotationKey: modelKey) as? String else { return nil }
        return try? JSONDecoder().decode(ShapeModel.self, from: Data(json.utf8))
    }

    var isArrow: Bool { model.kind == .arrow }

    var absolutePoints: [CGPoint] {
        model.points.map { CGPoint(x: $0.x + bounds.minX, y: $0.y + bounds.minY) }
    }

    /// Met à jour les points (absolus) d'une flèche et recalcule son cadre.
    func setAbsolutePoints(_ pts: [CGPoint]) {
        let b = ShapeGeometry.arrowBounds(pts, model.style)
        var m = model
        m.points = pts.map { CGPoint(x: $0.x - b.minX, y: $0.y - b.minY) }
        model = m
        bounds = b
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        if !isArrow { return bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p) }
        let pts = ShapeGeometry.route(absolutePoints, model.style.route)
        guard pts.count >= 2 else { return false }
        let tol = max(tolerance, model.style.width / 2 + 3)
        for i in 0..<(pts.count - 1) where ShapeGeometry.distance(p, toSegment: pts[i], pts[i + 1]) <= tol {
            return true
        }
        return false
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ShapeGeometry.draw(model, bounds: bounds, hideText: hidesText)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Remplace les tampons Folio d'un document chargé par des formes modifiables.
    static func restore(in doc: PDFDocument) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where !(a is ShapeAnnotation) && a.kind == "Stamp" {
                guard let m = decode(from: a) else { continue }
                let shape = ShapeAnnotation(model: m, bounds: a.bounds)
                page.removeAnnotation(a)
                page.addAnnotation(shape)
            }
        }
    }
}

// MARK: - Barre de réglages des formes

final class ShapeFormatBar: NSVisualEffectView {
    var onChange: ((ShapeStyle) -> Void)?
    var onEditText: (() -> Void)?
    private(set) var style = ShapeStyle()

    static let widths: [CGFloat] = [0.5, 1, 1.5, 2, 3, 4, 6, 8, 12]

    private let strokeLabel = NSTextField(labelWithString: "Contour")
    private let strokeWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
    private let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dashPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fillCheck = NSButton(checkboxWithTitle: "Fond", target: nil, action: nil)
    private let fillWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
    private let roundedCheck = NSButton(checkboxWithTitle: "Coins arrondis", target: nil, action: nil)
    private let routePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startLabel = NSTextField(labelWithString: "Début")
    private let startPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endLabel = NSTextField(labelWithString: "Fin")
    private let endPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swapButton = NSButton(frame: .zero)
    private let textButton = NSButton(title: "Texte…", target: nil, action: nil)
    private var lastFill = RGBA(1, 0.96, 0.62)

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        for l in [strokeLabel, startLabel, endLabel] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
        }
        for p in [widthPopup, dashPopup, routePopup, startPopup, endPopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.target = self
            p.action = #selector(changed(_:))
        }
        widthPopup.addItems(withTitles: Self.widths.map { $0 == 0.5 ? "0,5 pt" : ($0 == 1.5 ? "1,5 pt" : "\(Int($0)) pt") })
        dashPopup.addItems(withTitles: DashStyle.allCases.map { $0.title })
        routePopup.addItems(withTitles: ArrowRoute.allCases.map { $0.title })
        startPopup.addItems(withTitles: ArrowHead.allCases.map { $0.title })
        endPopup.addItems(withTitles: ArrowHead.allCases.map { $0.title })
        for w in [strokeWell, fillWell] {
            if #available(macOS 13.0, *) { w.colorWellStyle = .minimal }
            w.target = self
            w.action = #selector(changed(_:))
        }
        strokeWell.toolTip = "Couleur du contour"
        fillWell.toolTip = "Couleur du fond"
        for c in [fillCheck, roundedCheck] {
            c.controlSize = .small
            c.font = .systemFont(ofSize: 11)
            c.target = self
            c.action = #selector(changed(_:))
        }
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Inverser")
        swapButton.bezelStyle = .texturedRounded
        swapButton.controlSize = .small
        swapButton.toolTip = "Inverser début et fin"
        swapButton.target = self
        swapButton.action = #selector(swapHeads)
        textButton.bezelStyle = .texturedRounded
        textButton.controlSize = .small
        textButton.toolTip = "Écrire dans la forme (ou double-clic)"
        textButton.target = self
        textButton.action = #selector(editText)

        let stack = NSStackView(views: [strokeLabel, strokeWell, widthPopup, dashPopup, fillCheck, fillWell, roundedCheck,
                                        routePopup, startLabel, startPopup, swapButton, endLabel, endPopup, textButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            strokeWell.widthAnchor.constraint(equalToConstant: 34),
            strokeWell.heightAnchor.constraint(equalToConstant: 22),
            fillWell.widthAnchor.constraint(equalToConstant: 34),
            fillWell.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func mouseDown(with event: NSEvent) {}

    /// kind : type de forme ; canEditText : une forme fermée est sélectionnée.
    func configure(_ s: ShapeStyle, kind: ShapeKind, canEditText: Bool) {
        style = s
        let arrow = kind == .arrow
        for v in [fillCheck, fillWell] as [NSView] { v.isHidden = arrow }
        roundedCheck.isHidden = kind != .rect
        textButton.isHidden = arrow || !canEditText
        for v in [routePopup, startLabel, startPopup, swapButton, endLabel, endPopup] as [NSView] { v.isHidden = !arrow }

        strokeWell.color = s.stroke.color
        let wi = Self.widths.enumerated().min { abs($0.element - s.width) < abs($1.element - s.width) }?.offset ?? 3
        widthPopup.selectItem(at: wi)
        dashPopup.selectItem(at: DashStyle.allCases.firstIndex(of: s.dash) ?? 0)
        fillCheck.state = s.fill != nil ? .on : .off
        if let f = s.fill { lastFill = f }
        fillWell.color = lastFill.color
        fillWell.isEnabled = s.fill != nil
        roundedCheck.state = s.rounded ? .on : .off
        routePopup.selectItem(at: ArrowRoute.allCases.firstIndex(of: s.route) ?? 0)
        startPopup.selectItem(at: ArrowHead.allCases.firstIndex(of: s.startHead) ?? 0)
        endPopup.selectItem(at: ArrowHead.allCases.firstIndex(of: s.endHead) ?? 0)
        frame.size = fittingSize
    }

    @objc private func changed(_ sender: Any?) {
        var s = style
        s.stroke = RGBA(strokeWell.color)
        let wi = widthPopup.indexOfSelectedItem
        if Self.widths.indices.contains(wi) { s.width = Self.widths[wi] }
        s.dash = DashStyle.allCases[max(0, dashPopup.indexOfSelectedItem)]
        if sender as AnyObject? === fillWell { fillCheck.state = .on }
        lastFill = RGBA(fillWell.color)
        s.fill = fillCheck.state == .on ? lastFill : nil
        fillWell.isEnabled = fillCheck.state == .on
        s.rounded = roundedCheck.state == .on
        s.route = ArrowRoute.allCases[max(0, routePopup.indexOfSelectedItem)]
        s.startHead = ArrowHead.allCases[max(0, startPopup.indexOfSelectedItem)]
        s.endHead = ArrowHead.allCases[max(0, endPopup.indexOfSelectedItem)]
        style = s
        onChange?(s)
    }

    @objc private func swapHeads() {
        let a = startPopup.indexOfSelectedItem
        startPopup.selectItem(at: endPopup.indexOfSelectedItem)
        endPopup.selectItem(at: a)
        changed(nil)
    }

    @objc private func editText() { onEditText?() }
}
