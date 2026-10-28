import AppKit
import PDFKit

/// Vignette d'une page avec, en haut à droite, un signet pour la mettre en favoris en 1 clic.
private final class PageCell: NSView {
    let imageView = NSImageView()
    let numberLabel = NSTextField(labelWithString: "")
    let favoriteButton = NSButton(frame: .zero)
    var onToggleFavorite: (() -> Void)?
    private var imageHeight: NSLayoutConstraint!
    private var imageWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.layer?.shadowOpacity = 0.15
        imageView.layer?.shadowRadius = 2
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -1)

        numberLabel.font = .systemFont(ofSize: 10)
        numberLabel.textColor = .secondaryLabelColor
        numberLabel.alignment = .center

        favoriteButton.isBordered = false
        favoriteButton.bezelStyle = .regularSquare
        favoriteButton.imageScaling = .scaleProportionallyDown
        favoriteButton.wantsLayer = true
        favoriteButton.layer?.cornerRadius = 5
        favoriteButton.target = self
        favoriteButton.action = #selector(toggle)

        for v in [imageView, numberLabel, favoriteButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageHeight = imageView.heightAnchor.constraint(equalToConstant: 140)
        imageWidth = imageView.widthAnchor.constraint(equalToConstant: 112)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageWidth,
            imageHeight,
            numberLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 3),
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            favoriteButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 3),
            favoriteButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -3),
            favoriteButton.widthAnchor.constraint(equalToConstant: 20),
            favoriteButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    func configure(image: NSImage?, index: Int, width: CGFloat, height: CGFloat, favorite: Bool) {
        imageView.image = image
        imageWidth.constant = width
        imageHeight.constant = height
        numberLabel.stringValue = "\(index + 1)"
        // Couleur figée dans l'image : le surlignage de la ligne sélectionnée ne la blanchit plus.
        let color: NSColor = favorite ? .systemRed : NSColor(white: 0.35, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbol = NSImage(systemSymbolName: favorite ? "bookmark.fill" : "bookmark",
                             accessibilityDescription: favorite ? "Retirer des favoris" : "Ajouter aux favoris")
        favoriteButton.image = symbol?.withSymbolConfiguration(config)
        favoriteButton.image?.isTemplate = false
        favoriteButton.contentTintColor = nil
        favoriteButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(favorite ? 0.9 : 0.75).cgColor
        favoriteButton.toolTip = favorite ? "Retirer la page \(index + 1) des favoris" : "Ajouter la page \(index + 1) aux favoris"
    }

    @objc private func toggle() { onToggleFavorite?() }
}

/// Ligne du volet : surbrillance arrondie avec la même marge à gauche et à droite.
private final class PageRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
    override var isSelected: Bool {
        didSet { updateLabel() }
    }
    override var isEmphasized: Bool {
        didSet { updateLabel() }
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateLabel()
    }
    private func updateLabel() {
        for case let cell as PageCell in subviews {
            cell.numberLabel.textColor = (isSelected && isEmphasized) ? .white : .secondaryLabelColor
        }
    }
}

/// Zone de défilement verrouillée sur l'axe vertical (aucun déplacement latéral possible).
private final class VerticalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        r.origin.x = 0
        return r
    }
}

/// Liste des vignettes de pages (remplace PDFThumbnailView pour pouvoir y ajouter le signet favori).
final class PageListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    /// Largeur disponible pour une vignette : suit toujours la largeur du volet.
    private var available: CGFloat = 130

    weak var pdfView: PDFView? {
        didSet { reloadAll() }
    }
    /// Pages affichées (indices) ; nil = toutes les pages du document (onglet Vignettes).
    var pages: [Int]? {
        didSet { if pages != oldValue { table.reloadData(); syncSelection() } }
    }
    var isFavorite: (Int) -> Bool = { _ in false }
    var onToggleFavorite: ((Int) -> Void)?

    private let table = NSTableView()
    private var cache: [Int: NSImage] = [:]
    private var pending: [Int: DispatchWorkItem] = [:]
    private var syncing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        let clip = VerticalClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = table
        hasVerticalScroller = true
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        autohidesScrollers = true
        drawsBackground = false
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: nil)
        contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(widthChanged), name: NSView.frameDidChangeNotification, object: contentView)
    }

    @objc private func widthChanged() {
        // La colonne suit exactement la largeur visible (sinon les vignettes sont décalées et le signet sort du champ).
        let visible = contentView.bounds.width
        if let column = table.tableColumns.first, abs(column.width - visible) > 0.5 {
            column.width = max(20, visible - table.intercellSpacing.width)
        }
        if abs(table.frame.width - visible) > 0.5 { table.setFrameSize(NSSize(width: visible, height: table.frame.height)) }
        let w = max(30, visible - 40)
        guard abs(w - available) >= 1 else { return }
        available = w
        table.reloadData()
        syncSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func reloadAll() {
        cache.removeAll()
        table.reloadData()
        syncSelection()
    }

    /// Met à jour les signets (favoris) sans recalculer les vignettes.
    func reloadFavorites() {
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)), columnIndexes: [0])
    }

    /// Recalcule la vignette d'une page modifiée (annotations), avec un léger délai.
    func invalidate(pageIndex: Int) {
        pending[pageIndex]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cache[pageIndex] = nil
            if let row = self.row(for: pageIndex), row < self.table.numberOfRows {
                self.table.reloadData(forRowIndexes: [row], columnIndexes: [0])
            }
        }
        pending[pageIndex] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func pageIndex(_ row: Int) -> Int { pages.map { $0[row] } ?? row }
    private func row(for pageIndex: Int) -> Int? {
        if let pages { return pages.firstIndex(of: pageIndex) }
        return pageIndex
    }

    private func aspect(_ page: PDFPage) -> CGFloat {
        let b = page.bounds(for: .cropBox)
        guard b.width > 0 else { return 1.3 }
        let rotated = page.rotation % 180 != 0
        return rotated ? b.width / b.height : b.height / b.width
    }

    /// Taille d'affichage d'une page : occupe la largeur du volet en gardant ses proportions
    /// (portrait ou paysage) ; une page très allongée est limitée en hauteur et reste centrée.
    private func displaySize(_ index: Int) -> NSSize {
        let a = pdfView?.document?.page(at: index).map(aspect) ?? 1.3
        var w = available
        var h = w * a
        let maxH = max(available * 1.5, 60)
        if h > maxH { h = maxH; w = h / a }
        return NSSize(width: floor(w), height: floor(h))
    }

    private func thumbnail(_ index: Int, width: CGFloat) -> NSImage? {
        let needed = width * 2
        if let img = cache[index], img.size.width >= needed * 0.9 { return img }
        guard let page = pdfView?.document?.page(at: index) else { return nil }
        let w = max(240, ceil(needed / 80) * 80)
        let img = page.thumbnail(of: NSSize(width: w, height: w * aspect(page)), for: .cropBox)
        cache[index] = img
        return img
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { pages?.count ?? pdfView?.document?.pageCount ?? 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { displaySize(pageIndex(row)).height + 26 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PageRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PageCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? PageCell) ?? {
            let c = PageCell(frame: .zero)
            c.identifier = id
            return c
        }()
        let index = pageIndex(row)
        let size = displaySize(index)
        cell.configure(image: thumbnail(index, width: size.width), index: index, width: size.width, height: size.height, favorite: isFavorite(index))
        cell.onToggleFavorite = { [weak self] in
            guard let self else { return }
            self.onToggleFavorite?(index)
            if let r = self.row(for: index), r < self.table.numberOfRows {
                self.table.reloadData(forRowIndexes: [r], columnIndexes: [0])
            }
        }
        return cell
    }

    @objc private func rowClicked() {
        go(to: table.clickedRow)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        go(to: table.selectedRow)
    }

    private func go(to row: Int) {
        guard row >= 0, row < table.numberOfRows, let pdfView,
              let page = pdfView.document?.page(at: pageIndex(row)), pdfView.currentPage != page else { return }
        pdfView.go(to: page)
    }

    @objc private func pageChanged(_ note: Notification) {
        guard let v = note.object as? PDFView, v === pdfView else { return }
        syncSelection()
    }

    private func syncSelection() {
        guard let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        guard index >= 0 else { return }
        syncing = true
        defer { syncing = false }
        guard let row = row(for: index), row < table.numberOfRows else {
            table.deselectAll(nil)
            return
        }
        guard table.selectedRow != row else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}
