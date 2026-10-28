import AppKit

/// Barre de menus construite en code (pas de fichier .xib).
enum MainMenu {
    static func build() -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), goMenu(), toolsMenu(), windowMenu()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        return bar
    }

    private static func item(_ title: String, _ action: String?, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action.map { Selector($0) }, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        return i
    }

    private static func arrowKey(_ code: Int) -> String {
        String(Character(Unicode.Scalar(UInt32(code))!))
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Folio")
        m.addItem(item("À propos de Folio", "orderFrontStandardAboutPanel:"))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        m.addItem(servicesItem)
        NSApp.servicesMenu = services
        m.addItem(.separator())
        m.addItem(item("Masquer Folio", "hide:", "h"))
        m.addItem(item("Masquer les autres", "hideOtherApplications:", "h", [.command, .option]))
        m.addItem(item("Tout afficher", "unhideAllApplications:"))
        m.addItem(.separator())
        m.addItem(item("Quitter Folio", "terminate:", "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "Fichier")
        m.addItem(item("Accueil", "showHome:", "h", [.command, .shift]))
        m.addItem(item("Nouvel onglet…", "newWindowForTab:", "t"))
        m.addItem(item("Ouvrir…", "openDocument:", "o"))
        // NSDocumentController remplit automatiquement le sous-menu qui contient « clearRecentDocuments: ».
        let recent = NSMenu(title: "Ouvrir l'élément récent")
        recent.addItem(item("Effacer le menu", "clearRecentDocuments:"))
        let recentItem = NSMenuItem(title: "Ouvrir l'élément récent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        m.addItem(recentItem)
        m.addItem(.separator())
        m.addItem(item("Fermer", "performClose:", "w"))
        m.addItem(item("Enregistrer", "saveDocument:", "s"))
        m.addItem(item("Enregistrer sous…", "saveDocumentAs:", "s", [.command, .shift]))
        m.addItem(item("Revenir à la version enregistrée", "revertDocumentToSaved:"))
        m.addItem(.separator())
        m.addItem(item("Épingler sur l'accueil", "togglePinFile:"))
        m.addItem(.separator())
        m.addItem(item("Imprimer…", "printDocument:", "p"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Édition")
        m.addItem(item("Annuler", "undo:", "z"))
        m.addItem(item("Rétablir", "redo:", "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Couper", "cut:", "x"))
        m.addItem(item("Copier", "copy:", "c"))
        m.addItem(item("Coller", "paste:", "v"))
        m.addItem(item("Supprimer l'annotation", "deleteSelectedAnnotation:"))
        m.addItem(item("Tout sélectionner", "selectAll:", "a"))
        m.addItem(.separator())
        m.addItem(item("Rechercher…", "focusSearch:", "f"))
        m.addItem(item("Résultat suivant", "findNextResult:", "g"))
        m.addItem(item("Résultat précédent", "findPreviousResult:", "g", [.command, .shift]))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "Présentation")
        m.addItem(item("Masquer la barre latérale", "toggleThumbnails:", "s", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("Zoom avant", "folioZoomIn:", "+"))
        m.addItem(item("Zoom arrière", "folioZoomOut:", "-"))
        m.addItem(item("Taille réelle", "folioActualSize:", "0"))
        m.addItem(item("Ajuster à la fenêtre", "folioZoomToFit:", "9"))
        m.addItem(.separator())
        m.addItem(item("Page unique", "setDisplayModeFromMenu:", tag: 0))
        m.addItem(item("Page unique continue", "setDisplayModeFromMenu:", tag: 1))
        m.addItem(item("Deux pages", "setDisplayModeFromMenu:", tag: 2))
        m.addItem(item("Deux pages continues", "setDisplayModeFromMenu:", tag: 3))
        m.addItem(.separator())
        m.addItem(item("Plein écran", "toggleFullScreen:", "f", [.command, .control]))
        return m
    }

    private static func goMenu() -> NSMenu {
        let m = NSMenu(title: "Aller")
        m.addItem(item("Page précédente", "folioPreviousPage:", arrowKey(NSUpArrowFunctionKey), [.command, .option]))
        m.addItem(item("Page suivante", "folioNextPage:", arrowKey(NSDownArrowFunctionKey), [.command, .option]))
        m.addItem(item("Première page", "folioFirstPage:"))
        m.addItem(item("Dernière page", "folioLastPage:"))
        m.addItem(.separator())
        m.addItem(item("Aller à la page…", "goToPageNumber:", "g", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("Ajouter la page aux favoris", "toggleFavoriteCurrentPage:", "d"))
        return m
    }

    private static func toolsMenu() -> NSMenu {
        let m = NSMenu(title: "Outils")
        for t in Tool.allCases {
            m.addItem(item(t.title, "selectToolFromMenu:", t.keyEquivalent, tag: t.rawValue))
        }
        m.addItem(.separator())
        m.addItem(item("Gérer mes signatures…", "editSignature:"))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Fenêtre")
        m.addItem(item("Placer dans le Dock", "performMiniaturize:", "m"))
        m.addItem(item("Réduire/agrandir", "performZoom:"))
        m.addItem(.separator())
        m.addItem(item("Onglet suivant", "selectNextTab:", "\t", .control))
        m.addItem(item("Onglet précédent", "selectPreviousTab:", "\t", [.control, .shift]))
        m.addItem(.separator())
        m.addItem(item("Tout ramener au premier plan", "arrangeInFront:"))
        NSApp.windowsMenu = m
        return m
    }
}
