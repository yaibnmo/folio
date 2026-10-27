import AppKit
import PDFKit

/// Fabrique des annotations PDF standard (lisibles dans Acrobat, Aperçu, etc.).
enum AnnotationFactory {
    static func border(_ width: CGFloat) -> PDFBorder {
        let b = PDFBorder()
        b.lineWidth = width
        b.style = .solid
        return b
    }

    static func markup(_ subtype: PDFAnnotationSubtype, bounds b: NSRect, color: NSColor) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: b, forType: subtype, withProperties: nil)
        a.color = subtype == .highlight ? color.withAlphaComponent(0.5) : color
        // Points relatifs à l'origine de l'annotation : haut-gauche, haut-droit, bas-gauche, bas-droit.
        a.quadrilateralPoints = [
            NSValue(point: NSPoint(x: 0, y: b.height)),
            NSValue(point: NSPoint(x: b.width, y: b.height)),
            NSValue(point: NSPoint(x: 0, y: 0)),
            NSValue(point: NSPoint(x: b.width, y: 0)),
        ]
        return a
    }

    static func note(at p: NSPoint, text: String, color: NSColor) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
        a.iconType = .comment
        a.color = color
        a.contents = text
        return a
    }

    static func freeText(_ text: String, topLeft p: NSPoint, color: NSColor, fontSize: CGFloat) -> PDFAnnotation {
        let font = NSFont(name: "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let size = fittingSize(text, font: font)
        let a = PDFAnnotation(bounds: NSRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height),
                              forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.alignment = .left
        a.border = border(0)
        return a
    }

    static func fittingSize(_ text: String, font: NSFont) -> NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: 420, height: 100_000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: font])
        return NSSize(width: ceil(r.width) + 14, height: ceil(r.height) + 8)
    }

    static func shape(_ subtype: PDFAnnotationSubtype, from a: NSPoint, to b: NSPoint, color: NSColor, width: CGFloat) -> PDFAnnotation? {
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard r.width > 3, r.height > 3 else { return nil }
        let ann = PDFAnnotation(bounds: r.insetBy(dx: -width / 2, dy: -width / 2), forType: subtype, withProperties: nil)
        ann.color = color
        ann.border = border(width)
        return ann
    }

    static func arrow(from a: NSPoint, to b: NSPoint, color: NSColor, width: CGFloat) -> PDFAnnotation? {
        guard hypot(b.x - a.x, b.y - a.y) > 5 else { return nil }
        let pad = max(10, width * 5)
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -pad, dy: -pad)
        let ann = PDFAnnotation(bounds: r, forType: .line, withProperties: nil)
        ann.startPoint = NSPoint(x: a.x - r.minX, y: a.y - r.minY)
        ann.endPoint = NSPoint(x: b.x - r.minX, y: b.y - r.minY)
        ann.startLineStyle = .none
        ann.endLineStyle = .closedArrow
        ann.color = color
        ann.interiorColor = color
        ann.border = border(width)
        return ann
    }

    /// Dessin à main levée (plusieurs traits possibles, ex. une signature).
    static func ink(strokes: [[NSPoint]], color: NSColor, width: CGFloat) -> PDFAnnotation? {
        let all = strokes.flatMap { $0 }
        guard let first = all.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in all {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard (maxX - minX) + (maxY - minY) > 1.5 else { return nil }
        let pad = width * 2 + 2
        let r = NSRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
        let a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
        for stroke in strokes where !stroke.isEmpty {
            let local = stroke.map { NSPoint(x: $0.x - r.minX, y: $0.y - r.minY) }
            a.add(smoothPath(local, width: width))
        }
        a.color = color
        a.border = border(width)
        return a
    }

    static func smoothPath(_ pts: [NSPoint], width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: pts[0])
        if pts.count == 1 {
            path.line(to: NSPoint(x: pts[0].x + 0.6, y: pts[0].y))
            return path
        }
        if pts.count == 2 {
            path.line(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = NSPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
        }
        path.line(to: pts[pts.count - 1])
        return path
    }
}

enum AnnotationGeometry {
    /// Change le cadre d'une annotation ; les tracés (dessins, flèches) sont mis à l'échelle.
    static func setBounds(_ a: PDFAnnotation, to nb: NSRect) {
        let ob = a.bounds
        if ob.size != nb.size, ob.width > 0, ob.height > 0 {
            let sx = nb.width / ob.width
            let sy = nb.height / ob.height
            switch a.kind {
            case "Ink":
                let paths = a.paths ?? []
                for p in paths { a.remove(p) }
                for p in paths {
                    guard let c = p.copy() as? NSBezierPath else { continue }
                    c.transform(using: AffineTransform(scaleByX: sx, byY: sy))
                    a.add(c)
                }
            case "Line":
                a.startPoint = NSPoint(x: a.startPoint.x * sx, y: a.startPoint.y * sy)
                a.endPoint = NSPoint(x: a.endPoint.x * sx, y: a.endPoint.y * sy)
            default:
                break
            }
        }
        a.bounds = nb
    }
}
