import AppKit
import PDFKit

@objc(FolioDocument)
final class FolioDocument: NSDocument {
    private(set) var pdf: PDFDocument?

    // Enregistrement classique (⌘S / Enregistrer sous), pas d'écrasement automatique de l'original.
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        guard let pdf else { return }
        addWindowController(DocumentWindowController(pdf: pdf))
    }

    override func showWindows() {
        super.showWindows()
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        if !wc.unlockIfNeeded() {
            DispatchQueue.main.async { self.close() }
        }
    }

    override func close() {
        super.close()
        DispatchQueue.main.async {
            if !AppState.isQuitting && NSDocumentController.shared.documents.isEmpty {
                HomeWindowController.shared.show()
            }
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let doc = PDFDocument(data: data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Ce fichier n'est pas un PDF lisible."])
        }
        ShapeAnnotation.restore(in: doc)
        pdf = doc
    }

    override func data(ofType typeName: String) throws -> Data {
        for wc in windowControllers {
            (wc as? DocumentWindowController)?.pdfView.endTextEditing()
        }
        guard let data = pdf?.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "Impossible d'enregistrer ce PDF."])
        }
        return data
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        guard let pdf else { return }
        for wc in windowControllers {
            (wc as? DocumentWindowController)?.replacePDF(pdf)
        }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = (printInfo.copy() as? NSPrintInfo) ?? printInfo
        for (key, value) in printSettings {
            info.dictionary()[key.rawValue] = value
        }
        guard let op = pdf?.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                          userInfo: [NSLocalizedDescriptionKey: "Impossible d'imprimer ce PDF."])
        }
        return op
    }
}
