import AppKit

/// Petites boîtes de dialogue de saisie.
enum Prompt {
    static func multiline(title: String, message: String = "", initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 110))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 336, height: 110))
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.string = initial
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.layout()
        alert.window.initialFirstResponder = tv

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let t = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func line(title: String, message: String = "", initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func password(for name: String, retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "Mot de passe incorrect" : "Ce PDF est protégé"
        alert.informativeText = "Saisissez le mot de passe de « \(name) »."
        alert.addButton(withTitle: "Déverrouiller")
        alert.addButton(withTitle: "Annuler")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.layout()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
