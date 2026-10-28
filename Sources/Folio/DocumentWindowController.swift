import AppKit
import PDFKit

/// Fenêtre d'un document : vignettes à gauche, page à droite, barre d'outils.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSSplitViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, FolioPDFViewHost,
    NSTableViewDataSource, NSTableViewDelegate {

    let pdfView = FolioPDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    private let thumbnails = PageListView(frame: NSRect(x: 0, y: 0, width: 160, height: 700))
    private let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    private let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 700))
    private let sidebarSwitch = NSSegmentedControl(labels: ["Vignettes", "Favoris"], trackingMode: .selectOne, target: nil, action: nil)
    /// Onglet Favoris : mêmes vignettes que l'onglet Vignettes, limitées aux pages favorites.
    private let favoritesScroll = PageListView(frame: NSRect(x: 0, y: 0, width: 160, height: 700))
    private let favoritesEmpty = NSTextField(wrappingLabelWithString: "Aucune page favorite.\n\nCliquez sur le signet d'une vignette, clic droit sur une page → « Ajouter aux favoris », ou ⌘D.")
    private var favoritePages: [Int] = []
    private var subtitleTimer: Timer?
    let tabStrip = TabStripView(frame: .zero)
    private let collapseButton = NSButton(frame: .zero)
    private let floatingExpand = NSVisualEffectView(frame: .zero)

    private var currentTool: Tool = .select
    private var toolColors: [Tool: NSColor] = [:]
    private var toolControl: NSSegmentedControl?
    private var colorWell: NSColorWell?
    private var sizePopup: NSPopUpButton?
    private var searchField: NSSearchField?

    private var searchResults: [PDFSelection] = []
    private var searchIndex = -1
    private var lastQuery = ""
    private var signatureManager: SignatureManagerController?
    private var observers: [NSObjectProtocol] = []

    /// Taille : épaisseur du trait / taille du texte.
    private static let sizes: [(title: String, line: CGFloat, font: CGFloat)] = [
        ("Fin", 1, 11), ("Moyen", 2, 14), ("Épais", 4, 18), ("Très épais", 7, 24),
    ]
    private var sizeIndex = 1

    private enum Item {
        static let sidebar = NSToolbarItem.Identifier("folio.sidebar")
        static let zoom = NSToolbarItem.Identifier("folio.zoom")
        static let tools = NSToolbarItem.Identifier("folio.tools")
        static let color = NSToolbarItem.Identifier("folio.color")
        static let size = NSToolbarItem.Identifier("folio.size")
        static let search = NSToolbarItem.Identifier("folio.search")
    }

    init(pdf: PDFDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 420)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed   // onglets gérés par Folio (TabManager)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        Tool.allCases.forEach { toolColors[$0] = $0.defaultColor }
        buildContent(pdf)
        buildFloatingExpand()
        buildToolbar()
        let tabsAccessory = NSTitlebarAccessoryViewController()
        tabsAccessory.view = tabStrip
        tabsAccessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(tabsAccessory)
        window.center()
        _ = window.setFrameAutosaveName("FolioDocumentWindow")
        setTool(.select)
        applySize(1)
        observeFormEditing()
        pdfView.signatureColor = toolColors[.signature] ?? Tool.signature.defaultColor
        observers.append(NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadFavorites()
        })
        reloadFavorites()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Construction

    private func buildContent(_ pdf: PDFDocument) {
        pdfView.host = self
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.document = pdf

        thumbnails.isFavorite = { [weak self] i in self?.pdfViewIsFavorite(pageIndex: i) ?? false }
        thumbnails.onToggleFavorite = { [weak self] i in self?.pdfViewToggleFavorite(pageIndex: i) }
        thumbnails.pdfView = pdfView
        favoritesScroll.pages = []
        favoritesScroll.isFavorite = { [weak self] i in self?.pdfViewIsFavorite(pageIndex: i) ?? false }
        favoritesScroll.onToggleFavorite = { [weak self] i in self?.pdfViewToggleFavorite(pageIndex: i) }
        favoritesScroll.pdfView = pdfView
        buildSidebar()

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pdfView)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        split.autoresizingMask = [.width, .height]
        window?.contentView = split
        split.adjustSubviews()
        split.setPosition(170, ofDividerAt: 0)
    }

    private func buildSidebar() {
        sidebarSwitch.selectedSegment = 0
        sidebarSwitch.segmentDistribution = .fillEqually
        sidebarSwitch.controlSize = .small
        sidebarSwitch.target = self
        sidebarSwitch.action = #selector(sidebarSwitched(_:))

        favoritesScroll.isHidden = true

        favoritesEmpty.alignment = .center
        favoritesEmpty.textColor = .secondaryLabelColor
        favoritesEmpty.font = .systemFont(ofSize: 11)
        favoritesEmpty.isHidden = true

        collapseButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Réduire le volet")
        collapseButton.isBordered = false
        collapseButton.bezelStyle = .regularSquare
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.toolTip = "Réduire le volet (⌥⌘S)"
        collapseButton.target = self
        collapseButton.action = #selector(toggleThumbnails(_:))

        for v in [sidebarSwitch, collapseButton, thumbnails, favoritesScroll, favoritesEmpty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sidebarSwitch.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            sidebarSwitch.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            sidebarSwitch.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -6),
            collapseButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            collapseButton.centerYAnchor.constraint(equalTo: sidebarSwitch.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 22),
            collapseButton.heightAnchor.constraint(equalToConstant: 22),
            thumbnails.topAnchor.constraint(equalTo: sidebarSwitch.bottomAnchor, constant: 6),
            thumbnails.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            thumbnails.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            favoritesScroll.topAnchor.constraint(equalTo: sidebarSwitch.bottomAnchor, constant: 6),
            favoritesScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            favoritesScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            favoritesScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            favoritesEmpty.centerYAnchor.constraint(equalTo: favoritesScroll.centerYAnchor),
            favoritesEmpty.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            favoritesEmpty.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
        ])
    }

    /// Petit bouton flottant (coin haut-gauche du PDF) pour rouvrir le volet quand il est réduit.
    private func buildFloatingExpand() {
        floatingExpand.material = .popover
        floatingExpand.blendingMode = .withinWindow
        floatingExpand.state = .active
        floatingExpand.wantsLayer = true
        floatingExpand.layer?.cornerRadius = 8
        floatingExpand.layer?.borderWidth = 0.5
        floatingExpand.layer?.borderColor = NSColor.separatorColor.cgColor
        floatingExpand.translatesAutoresizingMaskIntoConstraints = false
        floatingExpand.isHidden = true

        let button = NSButton(frame: .zero)
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Afficher le volet")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .labelColor
        button.toolTip = "Afficher le volet (⌥⌘S)"
        button.target = self
        button.action = #selector(toggleThumbnails(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        floatingExpand.addSubview(button)

        pdfView.addSubview(floatingExpand)
        NSLayoutConstraint.activate([
            floatingExpand.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor, constant: 10),
            floatingExpand.topAnchor.constraint(equalTo: pdfView.topAnchor, constant: 10),
            floatingExpand.widthAnchor.constraint(equalToConstant: 34),
            floatingExpand.heightAnchor.constraint(equalToConstant: 30),
            button.centerXAnchor.constraint(equalTo: floatingExpand.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: floatingExpand.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func updateFloatingExpand() {
        let collapsed = sidebar.superview == nil
        if collapsed {
            floatingExpand.alphaValue = 0
            floatingExpand.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                floatingExpand.animator().alphaValue = 1
            }
        } else {
            floatingExpand.isHidden = true
        }
        if collapsed, pdfView.subviews.last !== floatingExpand {
            // reste au-dessus des vues internes de PDFKit
            floatingExpand.removeFromSuperview()
            pdfView.addSubview(floatingExpand)
            NSLayoutConstraint.activate([
                floatingExpand.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor, constant: 10),
                floatingExpand.topAnchor.constraint(equalTo: pdfView.topAnchor, constant: 10),
            ])
        }
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "FolioToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.sidebar, Item.zoom, .flexibleSpace, Item.tools, Item.color, Item.size, .flexibleSpace, Item.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.sidebar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Vignettes"
            item.toolTip = "Afficher ou masquer les vignettes (⌥⌘S)"
            item.image = symbol("sidebar.left", "Vignettes")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleThumbnails(_:))
            item.visibilityPriority = .user   // toujours visible, même fenêtre étroite
            return item

        case Item.zoom:
            let seg = NSSegmentedControl(images: [symbol("minus.magnifyingglass", "Zoom arrière"),
                                                  symbol("plus.magnifyingglass", "Zoom avant")],
                                         trackingMode: .momentary, target: self, action: #selector(zoomSegment(_:)))
            seg.setToolTip("Zoom arrière (⌘-)", forSegment: 0)
            seg.setToolTip("Zoom avant (⌘+)", forSegment: 1)
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Zoom"
            item.view = seg
            item.visibilityPriority = .low
            return item

        case Item.tools:
            let seg = NSSegmentedControl(images: Tool.allCases.map { symbol($0.symbolName, $0.title) },
                                         trackingMode: .selectOne, target: self, action: #selector(toolSegment(_:)))
            for t in Tool.allCases {
                let key = t.keyEquivalent.isEmpty ? "" : " (⌘\(t.keyEquivalent))"
                seg.setToolTip(t.title + key, forSegment: t.rawValue)
            }
            seg.selectedSegment = currentTool.rawValue
            toolControl = seg
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Outils"
            item.view = seg
            item.visibilityPriority = .high
            return item

        case Item.color:
            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
            well.color = toolColors[currentTool] ?? .black
            well.target = self
            well.action = #selector(colorChanged(_:))
            colorWell = well
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Couleur"
            item.toolTip = "Couleur de l'outil ou de l'annotation sélectionnée"
            item.view = well
            item.visibilityPriority = .high
            return item

        case Item.size:
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24), pullsDown: false)
            pop.addItems(withTitles: Self.sizes.map { $0.title })
            pop.selectItem(at: sizeIndex)
            pop.target = self
            pop.action = #selector(sizeChanged(_:))
            sizePopup = pop
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Taille"
            item.toolTip = "Épaisseur du trait et taille du texte"
            item.view = pop
            item.visibilityPriority = .high
            return item

        case Item.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Rechercher"
            item.searchField.sendsWholeSearchString = true
            item.searchField.target = self
            item.searchField.action = #selector(searchAction(_:))
            item.searchField.delegate = self
            searchField = item.searchField
            return item

        default:
            return nil
        }
    }

    // MARK: - Outils, couleur, taille

    func setTool(_ t: Tool) {
        currentTool = t
        pdfView.tool = t
        toolControl?.selectedSegment = t.rawValue
        let c = toolColors[t] ?? .black
        colorWell?.color = c
        pdfView.color = c
    }

    private func chooseTool(_ t: Tool) {
        if t == .signature && SignatureStore.load().isEmpty {
            let previous = currentTool
            setTool(previous)
            showSignatureManager { [weak self] saved in self?.setTool(saved ? .signature : previous) }
            return
        }
        setTool(t)
    }

    @objc func toolSegment(_ sender: NSSegmentedControl) {
        if let t = Tool(rawValue: sender.selectedSegment) { chooseTool(t) }
    }

    @objc func selectToolFromMenu(_ sender: NSMenuItem) {
        if let t = Tool(rawValue: sender.tag) { chooseTool(t) }
    }

    @objc func colorChanged(_ sender: NSColorWell) {
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        if pdfView.selectedAnnotation != nil {
            pdfView.applyColorToSelection(c)
        } else {
            toolColors[currentTool] = c
            pdfView.color = c
            if currentTool == .signature { pdfView.signatureColor = c }
        }
    }

    @objc func sizeChanged(_ sender: NSPopUpButton) {
        applySize(sender.indexOfSelectedItem)
    }

    private func applySize(_ index: Int) {
        sizeIndex = max(0, min(index, Self.sizes.count - 1))
        pdfView.lineWidth = Self.sizes[sizeIndex].line
        pdfView.fontSize = Self.sizes[sizeIndex].font
        sizePopup?.selectItem(at: sizeIndex)
    }

    // MARK: - Signature

    @objc func editSignature(_ sender: Any?) {
        showSignatureManager(completion: nil)
    }

    private func showSignatureManager(completion: ((Bool) -> Void)?) {
        guard signatureManager == nil else { return }
        let manager = SignatureManagerController()
        guard let window, let sheet = manager.window else { return }
        signatureManager = manager
        window.beginSheet(sheet) { [weak self] response in
            self?.signatureManager = nil
            completion?(response == .OK)
        }
    }

    // MARK: - FolioPDFViewHost

    func pdfViewDidModify(pageIndex: Int) {
        thumbnails.invalidate(pageIndex: pageIndex)
        favoritesScroll.invalidate(pageIndex: pageIndex)
    }

    func pdfViewWantsSignatureManager() {
        showSignatureManager(completion: nil)
    }

    func pdfViewDidPlaceSignature() {
        if currentTool == .signature { setTool(.select) }
    }

    func pdfViewColor(for tool: Tool) -> NSColor {
        toolColors[tool] ?? tool.defaultColor
    }

    private var fileURL: URL? { (document as? NSDocument)?.fileURL }

    func pdfViewIsFavorite(pageIndex: Int) -> Bool {
        guard let url = fileURL else { return false }
        return LibraryStore.shared.isFavorite(page: pageIndex, of: url)
    }

    func pdfViewToggleFavorite(pageIndex: Int) {
        guard let url = fileURL else {
            flash("Enregistrez d'abord le document pour utiliser les favoris")
            return
        }
        let added = LibraryStore.shared.toggleFavorite(page: pageIndex, of: url)
        flash(added ? "★ Page \(pageIndex + 1) ajoutée aux favoris" : "Page \(pageIndex + 1) retirée des favoris")
    }

    func pdfViewWantsTool(_ tool: Tool) {
        setTool(tool)
    }

    func pdfViewSelectionChanged(_ annotation: PDFAnnotation?) {
        colorWell?.color = annotation?.displayColor ?? (toolColors[currentTool] ?? .black)
    }

    // MARK: - Affichage

    private var sidebarWidth: CGFloat = 170
    private var sidebarAnimating = false

    /// Ouvre / ferme le volet avec une courte animation (le séparateur est retiré une fois fermé).
    @objc func toggleThumbnails(_ sender: Any?) {
        guard !sidebarAnimating else { return }
        if sidebar.superview != nil {
            sidebarWidth = max(130, sidebar.frame.width)
            animateSidebar(from: sidebar.frame.width, to: 0) { [weak self] in
                guard let self else { return }
                self.split.removeArrangedSubview(self.sidebar)
                self.sidebar.removeFromSuperview()
                self.sidebar.isHidden = true
                self.split.adjustSubviews()
                self.split.needsDisplay = true
                self.updateFloatingExpand()
            }
        } else {
            sidebar.isHidden = false
            split.insertArrangedSubview(sidebar, at: 0)
            split.adjustSubviews()
            sidebarAnimating = true
            split.setPosition(0, ofDividerAt: 0)
            updateFloatingExpand()
            animateSidebar(from: 0, to: sidebarWidth) { [weak self] in
                self?.split.needsDisplay = true
            }
        }
    }

    /// À l'ouverture d'un PDF, le volet garde une largeur confortable.
    func ensureSidebarWidth() {
        guard sidebar.superview != nil, sidebar.frame.width < 150 else { return }
        split.setPosition(170, ofDividerAt: 0)
    }

    private func animateSidebar(from start: CGFloat, to end: CGFloat, completion: @escaping () -> Void) {
        sidebarAnimating = true
        let duration = 0.24
        let t0 = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(1, (ProcessInfo.processInfo.systemUptime - t0) / duration)
            let eased = 1 - pow(1 - p, 3)   // ralentit en fin de course
            self.split.setPosition(start + (end - start) * CGFloat(eased), ofDividerAt: 0)
            if p >= 1 {
                t.invalidate()
                self.sidebarAnimating = false
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        sidebar.superview == nil || sidebar.isHidden
    }

    @objc func zoomSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { pdfView.zoomOut(sender) } else { pdfView.zoomIn(sender) }
    }

    @objc func folioZoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func folioZoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }

    @objc func folioActualSize(_ sender: Any?) {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    @objc func folioZoomToFit(_ sender: Any?) { pdfView.autoScales = true }

    @objc func setDisplayModeFromMenu(_ sender: NSMenuItem) {
        if let mode = PDFDisplayMode(rawValue: sender.tag) {
            pdfView.displayMode = mode
            pdfView.autoScales = true
        }
    }

    @objc func folioNextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func folioPreviousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func folioFirstPage(_ sender: Any?) { pdfView.goToFirstPage(sender) }
    @objc func folioLastPage(_ sender: Any?) { pdfView.goToLastPage(sender) }

    @objc func goToPageNumber(_ sender: Any?) {
        guard let doc = pdfView.document, doc.pageCount > 0 else { return }
        let current = pdfView.currentPage.map { doc.index(for: $0) + 1 } ?? 1
        guard let text = Prompt.line(title: "Aller à la page",
                                     message: "Numéro de page (1 à \(doc.pageCount)) :",
                                     initial: "\(current)"),
              let n = Int(text), n >= 1, n <= doc.pageCount,
              let page = doc.page(at: n - 1) else { return }
        pdfView.go(to: page)
    }

    // MARK: - Recherche

    @objc func focusSearch(_ sender: Any?) {
        if let searchField { window?.makeFirstResponder(searchField) }
    }

    @objc func searchAction(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        if query == lastQuery, !searchResults.isEmpty {
            stepSearch(1)
            return
        }
        lastQuery = query
        searchResults = pdfView.document?.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
        searchIndex = -1
        guard !searchResults.isEmpty else {
            pdfView.highlightedSelections = nil
            window?.subtitle = "Aucun résultat"
            NSSound.beep()
            return
        }
        for r in searchResults { r.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        pdfView.highlightedSelections = searchResults
        stepSearch(1)
    }

    @objc func findNextResult(_ sender: Any?) { stepSearch(1) }
    @objc func findPreviousResult(_ sender: Any?) { stepSearch(-1) }

    private func stepSearch(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count
        let sel = searchResults[searchIndex]
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
        window?.subtitle = "Résultat \(searchIndex + 1) sur \(searchResults.count)"
    }

    private func flash(_ message: String) {
        window?.subtitle = message
        subtitleTimer?.invalidate()
        subtitleTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.window?.subtitle = self.searchResults.isEmpty ? "" : "Résultat \(self.searchIndex + 1) sur \(self.searchResults.count)"
        }
    }

    private func clearSearch() {
        searchResults = []
        searchIndex = -1
        lastQuery = ""
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        window?.subtitle = ""
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        clearSearch()
    }

    // MARK: - Onglets

    /// Bouton « + » de la barre d'onglets (et ⌘T) : ouvrir un ou plusieurs PDF dans de nouveaux onglets.
    @objc override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    func windowWillClose(_ notification: Notification) {
        TabManager.shared.remove(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if TabManager.shared.active !== self, TabManager.shared.tabs.contains(where: { $0 === self }) {
            TabManager.shared.select(self)
        }
    }

    // MARK: - Favoris

    @objc func toggleFavoriteCurrentPage(_ sender: Any?) {
        guard let page = pdfView.currentPage, let i = pdfView.document?.index(for: page) else { return }
        pdfViewToggleFavorite(pageIndex: i)
    }

    @objc func togglePinFile(_ sender: Any?) {
        guard let url = fileURL else { return }
        LibraryStore.shared.togglePin(url)
        flash(LibraryStore.shared.isPinned(url) ? "★ Épinglé sur l'accueil" : "Retiré de l'accueil")
    }

    @objc private func sidebarSwitched(_ sender: NSSegmentedControl) {
        updateSidebarVisibility()
    }

    private func updateSidebarVisibility() {
        let showFavorites = sidebarSwitch.selectedSegment == 1
        thumbnails.isHidden = showFavorites
        favoritesScroll.isHidden = !showFavorites
        favoritesEmpty.isHidden = !showFavorites || !favoritePages.isEmpty
    }

    private func reloadFavorites() {
        let count = pdfView.document?.pageCount ?? 0
        favoritePages = fileURL.map { LibraryStore.shared.favoritePages(for: $0) }?.filter { $0 < count } ?? []
        favoritesScroll.pages = favoritePages
        favoritesScroll.reloadFavorites()
        thumbnails.reloadFavorites()
        sidebarSwitch.setLabel(favoritePages.isEmpty ? "Favoris" : "Favoris (\(favoritePages.count))", forSegment: 1)
        updateSidebarVisibility()
    }

    // MARK: - Menus

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectToolFromMenu(_:)):
            item.state = item.tag == currentTool.rawValue ? .on : .off
        case #selector(setDisplayModeFromMenu(_:)):
            item.state = pdfView.displayMode.rawValue == item.tag ? .on : .off
        case #selector(toggleThumbnails(_:)):
            item.title = sidebar.isHidden ? "Afficher la barre latérale" : "Masquer la barre latérale"
        case #selector(findNextResult(_:)), #selector(findPreviousResult(_:)):
            return !searchResults.isEmpty
        case #selector(toggleFavoriteCurrentPage(_:)):
            if let page = pdfView.currentPage, let i = pdfView.document?.index(for: page) {
                item.title = pdfViewIsFavorite(pageIndex: i) ? "Retirer la page des favoris" : "Ajouter la page aux favoris"
            }
            return fileURL != nil
        case #selector(togglePinFile(_:)):
            if let url = fileURL { item.title = LibraryStore.shared.isPinned(url) ? "Désépingler de l'accueil" : "Épingler sur l'accueil" }
            return fileURL != nil
        default:
            break
        }
        return true
    }

    // MARK: - Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { sidebarAnimating ? 0 : 130 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 320 }

    // MARK: - Document

    /// Formulaires : PDFKit ne passe pas par l'annulation, on signale donc la modification nous-mêmes.
    private func observeFormEditing() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let v = note.object as? NSView, v.isDescendant(of: self.pdfView) else { return }
            (self.document as? NSDocument)?.updateChangeCount(.changeDone)
        })
        observers.append(nc.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] note in
            guard let a = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                  a.kind == "Widget", a.widgetFieldType == .button else { return }
            (self?.document as? NSDocument)?.updateChangeCount(.changeDone)
        })
    }

    func unlockIfNeeded() -> Bool {
        guard let doc = pdfView.document, doc.isLocked else { return true }
        let name = (document as? NSDocument)?.displayName ?? "ce document"
        var retry = false
        while true {
            guard let password = Prompt.password(for: name, retry: retry) else { return false }
            if doc.unlock(withPassword: password) {
                replacePDF(doc)
                return true
            }
            retry = true
        }
    }

    func replacePDF(_ pdf: PDFDocument) {
        clearSearch()
        pdfView.document = nil
        pdfView.document = pdf
        thumbnails.pdfView = pdfView
        favoritesScroll.pdfView = pdfView
        reloadFavorites()
    }
}
