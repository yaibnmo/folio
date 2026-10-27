import AppKit

@objc(FolioApplication)
final class FolioApplication: NSApplication {}

/// Contrôleur de documents : mémorise les fichiers ouverts pour l'écran d'accueil.
final class FolioDocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument) { doc, already, error in
            if doc != nil {
                LibraryStore.shared.noteOpened(url)
                HomeWindowController.shared.window?.orderOut(nil)
            }
            completionHandler(doc, already, error)
        }
    }

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        if sender != nil { LibraryStore.shared.clearRecents() }
    }
}
