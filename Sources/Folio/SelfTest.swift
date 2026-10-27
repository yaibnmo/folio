import AppKit
import PDFKit

enum SelfTest {
    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String] = []

        let blank = NSImage(size: NSSize(width: 595, height: 842), flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            return true
        }
        guard let page = PDFPage(image: blank) else {
            print("SELFTEST: impossible de créer la page")
            return
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)

        var profile = SignatureProfile()
        var wave: [[Double]] = []
        for x in stride(from: 0.0, through: 160.0, by: 4.0) {
            wave.append([x, 30 + 22 * sin(x / 14) + (x > 80 ? 8 : 0)])
        }
        profile.strokes = [wave, [[20, 4], [150, 8]]]
        profile.name = "Jean Dupont"
        profile.fontName = SignatureFonts.available.first?.postScript ?? "SnellRoundhand"
        report.append("Polices cursives disponibles : \(SignatureFonts.available.map { $0.label }.joined(separator: ", "))")

        var y: CGFloat = 700
        for style in SignatureStyle.allCases {
            guard let img = SignatureRenderer.image(style, profile: profile, color: NSColor(srgbRed: 0.05, green: 0.1, blue: 0.4, alpha: 1)) else {
                report.append("ERREUR rendu \(style.title)")
                continue
            }
            var s = 220 / img.size.width
            if img.size.height * s > 90 { s = 90 / img.size.height }
            let rect = NSRect(x: 80, y: y, width: img.size.width * s, height: img.size.height * s)
            let a: PDFAnnotation
            if style == .drawn {
                let pts = profile.drawnStrokes.map { $0.map { NSPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) } }
                a = AnnotationFactory.ink(strokes: pts, color: .black, width: 1.6)!
            } else {
                a = SignatureStampAnnotation(bounds: rect, image: img)
            }
            page.addAnnotation(a)
            y -= 140
        }
        page.addAnnotation(AnnotationFactory.markup(.highlight, bounds: NSRect(x: 340, y: 700, width: 180, height: 16), color: Palette.colors[0].color))
        page.addAnnotation(AnnotationFactory.freeText("Zone de texte", topLeft: NSPoint(x: 340, y: 650), color: .red, fontSize: 14))
        if let arrow = AnnotationFactory.arrow(from: NSPoint(x: 340, y: 560), to: NSPoint(x: 480, y: 600), color: .red, width: 2) {
            page.addAnnotation(arrow)
        }

        // Page 2 : formes et flèches
        if let page2 = PDFPage(image: blank) {
            doc.insert(page2, at: 1)
            var box = ShapeStyle()
            box.stroke = RGBA(0.15, 0.3, 0.85); box.width = 3; box.dash = .dashed; box.fill = RGBA(0.9, 0.94, 1); box.rounded = true
            var m = ShapeModel(kind: .rect, style: box)
            m.text = "Texte dans\nune forme"
            var ts = ShapeText(); ts.size = 18; ts.bold = true; m.textStyle = ts
            page2.addAnnotation(ShapeAnnotation(model: m, bounds: NSRect(x: 60, y: 650, width: 200, height: 110)))
            var oval = ShapeStyle(); oval.fill = RGBA(1, 0.95, 0.6); oval.dash = .dotted; oval.width = 4
            var om = ShapeModel(kind: .ellipse, style: oval); om.text = "Ellipse"
            page2.addAnnotation(ShapeAnnotation(model: om, bounds: NSRect(x: 330, y: 650, width: 200, height: 110)))
            let arrows: [(ArrowRoute, ArrowHead, ArrowHead, [CGPoint], CGFloat)] = [
                (.straight, .closed, .closed, [CGPoint(x: 60, y: 560), CGPoint(x: 260, y: 600)], 3),
                (.elbow, .none, .open, [CGPoint(x: 330, y: 600), CGPoint(x: 530, y: 520)], 2),
                (.doubleElbow, .circle, .diamond, [CGPoint(x: 60, y: 480), CGPoint(x: 260, y: 380)], 2),
                (.curve, .bar, .closed, ShapeGeometry.simplify((0...60).map { i in
                    let t = CGFloat(i) / 60
                    return CGPoint(x: 330 + 200 * t, y: 420 + 50 * sin(t * 6))
                }), 2.5),
            ]
            for (route, start, end, pts, width) in arrows {
                var st = ShapeStyle(); st.route = route; st.startHead = start; st.endHead = end; st.width = width
                st.stroke = RGBA(0.85, 0.2, 0.2)
                let a = ShapeAnnotation(model: ShapeModel(kind: .arrow, style: st), bounds: .zero)
                a.setAbsolutePoints(pts)
                page2.addAnnotation(a)
            }
        }

        let pdfURL = dir.appendingPathComponent("selftest.pdf")
        report.append("Écriture du PDF : \(doc.write(to: pdfURL) ? "ok" : "ÉCHEC")")
        guard let reloaded = PDFDocument(url: pdfURL), let p2 = reloaded.page(at: 0) else {
            report.append("ÉCHEC du rechargement")
            finish(report, dir)
            return
        }
        report.append("Annotations rechargées : \(p2.annotations.map { $0.kind }.joined(separator: ", "))")
        if let shapesPage = reloaded.page(at: 1) {
            let decoded = shapesPage.annotations.compactMap { ShapeAnnotation.decode(from: $0) }
            report.append("Formes rechargées : \(shapesPage.annotations.count) annotations, \(decoded.count) réglages Folio relus")
            ShapeAnnotation.restore(in: reloaded)
            report.append("Formes modifiables après restauration : \(shapesPage.annotations.filter { $0 is ShapeAnnotation }.count)")
            let t2 = shapesPage.thumbnail(of: NSSize(width: 850, height: 1200), for: .mediaBox)
            if let tiff = t2.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("selftest-formes.png"))
            }
        }
        let thumb = p2.thumbnail(of: NSSize(width: 850, height: 1200), for: .mediaBox)
        if let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("selftest.png"))
            report.append("Rendu : selftest.png")
        }
        finish(report, dir)
    }

    private static func finish(_ report: [String], _ dir: URL) {
        let text = report.joined(separator: "\n")
        print(text)
        try? text.write(to: dir.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
    }
}
