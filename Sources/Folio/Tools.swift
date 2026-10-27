import AppKit
import PDFKit

/// Outils disponibles dans la barre d'outils et le menu « Outils ».
enum Tool: Int, CaseIterable {
    case select, highlight, underline, strike, note, text, ink, rect, oval, arrow, signature

    var title: String {
        switch self {
        case .select: return "Sélection"
        case .highlight: return "Surligner"
        case .underline: return "Souligner"
        case .strike: return "Barrer"
        case .note: return "Note"
        case .text: return "Zone de texte"
        case .ink: return "Dessin à main levée"
        case .rect: return "Rectangle"
        case .oval: return "Ellipse"
        case .arrow: return "Flèche"
        case .signature: return "Signature"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strike: return "strikethrough"
        case .note: return "note.text"
        case .text: return "character.textbox"
        case .ink: return "scribble"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .arrow: return "arrow.up.right"
        case .signature: return "signature"
        }
    }

    /// Raccourcis ⌘1 … ⌘8.
    var keyEquivalent: String { rawValue < 8 ? String(rawValue + 1) : "" }

    var isMarkup: Bool { self == .highlight || self == .underline || self == .strike }

    var defaultColor: NSColor {
        switch self {
        case .highlight, .note:
            return NSColor(srgbRed: 1.0, green: 0.86, blue: 0.2, alpha: 1)
        case .underline:
            return NSColor(srgbRed: 0.1, green: 0.45, blue: 0.95, alpha: 1)
        case .strike, .ink, .rect, .oval, .arrow:
            return NSColor(srgbRed: 0.9, green: 0.15, blue: 0.15, alpha: 1)
        case .select, .text, .signature:
            return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)
        }
    }
}

extension PDFAnnotation {
    /// Sous-type sans le « / » : Highlight, Ink, FreeText, Widget…
    var kind: String { (type ?? "").replacingOccurrences(of: "/", with: "") }

    /// Annotations que l'utilisateur peut sélectionner (pas les champs de formulaire ni les liens).
    var isUserSelectable: Bool { !["Widget", "Link", "Popup"].contains(kind) }
    var isMovable: Bool { ["Text", "FreeText", "Ink", "Square", "Circle", "Line", "Stamp"].contains(kind) }
    var isResizable: Bool {
        if self is ShapeAnnotation { return false }  // poignées dédiées
        return ["FreeText", "Ink", "Square", "Circle", "Line", "Stamp"].contains(kind)
    }
    var keepsAspectRatio: Bool { kind == "Ink" || kind == "Stamp" }

    var displayColor: NSColor {
        if let shape = self as? ShapeAnnotation { return shape.model.style.stroke.color }
        return kind == "FreeText" ? (fontColor ?? .black) : color.withAlphaComponent(1)
    }
}

/// Élément de menu qui exécute une closure (la closure est retenue par l'élément).
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func runMenuAction(_ sender: Any?) {
        DebugLog.write("menu: \((sender as? NSMenuItem)?.title ?? "?")")
        handler()
    }

    static func item(_ title: String, image: NSImage? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runMenuAction(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.image = image
        return item
    }

    static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Couleurs proposées dans les menus contextuels.
enum Palette {
    static let colors: [(name: String, color: NSColor)] = [
        ("Jaune", NSColor(srgbRed: 1.0, green: 0.86, blue: 0.2, alpha: 1)),
        ("Vert", NSColor(srgbRed: 0.45, green: 0.85, blue: 0.35, alpha: 1)),
        ("Bleu", NSColor(srgbRed: 0.35, green: 0.7, blue: 1.0, alpha: 1)),
        ("Rose", NSColor(srgbRed: 1.0, green: 0.5, blue: 0.75, alpha: 1)),
        ("Orange", NSColor(srgbRed: 1.0, green: 0.6, blue: 0.2, alpha: 1)),
        ("Rouge", NSColor(srgbRed: 0.9, green: 0.15, blue: 0.15, alpha: 1)),
        ("Noir", NSColor(srgbRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)),
    ]

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}
