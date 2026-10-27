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

        let pdfURL = dir.appendingPathComponent("selftest.pdf")
        report.append("Écriture du PDF : \(doc.write(to: pdfURL) ? "ok" : "ÉCHEC")")
        guard let reloaded = PDFDocument(url: pdfURL), let p2 = reloaded.page(at: 0) else {
            report.append("ÉCHEC du rechargement")
            finish(report, dir)
            return
        }
        report.append("Annotations rechargées : \(p2.annotations.map { $0.kind }.joined(separator: ", "))")
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
