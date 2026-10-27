import AppKit
import PDFKit

/// Fichiers récents, fichiers épinglés et pages favorites (stockés dans Folio, pas dans les PDF).
final class LibraryStore {
    static let shared = LibraryStore()
    static let didChange = Notification.Name("FolioLibraryDidChange")

    struct Entry {
        let url: URL
        let date: Date
    }

    private let defaults = UserDefaults.standard

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Récents

    var recents: [Entry] {
        let raw = defaults.array(forKey: "recents") as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let path = d["path"] as? String, let t = d["date"] as? Double else { return nil }
            return Entry(url: URL(fileURLWithPath: path), date: Date(timeIntervalSince1970: t))
        }
    }

    private func saveRecents(_ list: [Entry]) {
        defaults.set(list.map { ["path": $0.url.path, "date": $0.date.timeIntervalSince1970] }, forKey: "recents")
        changed()
    }

    func noteOpened(_ url: URL) {
        var list = recents.filter { $0.url.path != url.path }
        list.insert(Entry(url: url, date: Date()), at: 0)
        saveRecents(Array(list.prefix(50)))
    }

    func lastOpened(_ url: URL) -> Date? {
        recents.first { $0.url.path == url.path }?.date
    }

    func removeRecent(_ url: URL) {
        saveRecents(recents.filter { $0.url.path != url.path })
    }

    func clearRecents() {
        saveRecents([])
    }

    // MARK: Fichiers épinglés

    var pinned: [URL] {
        (defaults.stringArray(forKey: "pinned") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func isPinned(_ url: URL) -> Bool {
        (defaults.stringArray(forKey: "pinned") ?? []).contains(url.path)
    }

    func togglePin(_ url: URL) {
        var list = defaults.stringArray(forKey: "pinned") ?? []
        if let i = list.firstIndex(of: url.path) { list.remove(at: i) } else { list.insert(url.path, at: 0) }
        defaults.set(list, forKey: "pinned")
        changed()
    }

    // MARK: Pages favorites

    func favoritePages(for url: URL) -> [Int] {
        (defaults.dictionary(forKey: "favoritePages")?[url.path] as? [Int]) ?? []
    }

    func isFavorite(page index: Int, of url: URL) -> Bool {
        favoritePages(for: url).contains(index)
    }

    /// Renvoie true si la page est maintenant en favori.
    @discardableResult
    func toggleFavorite(page index: Int, of url: URL) -> Bool {
        var all = defaults.dictionary(forKey: "favoritePages") ?? [:]
        var pages = all[url.path] as? [Int] ?? []
        let added: Bool
        if let i = pages.firstIndex(of: index) {
            pages.remove(at: i)
            added = false
        } else {
            pages.append(index)
            pages.sort()
            added = true
        }
        all[url.path] = pages.isEmpty ? nil : pages
        defaults.set(all, forKey: "favoritePages")
        changed()
        return added
    }
}

/// Miniatures de première page, calculées en arrière-plan.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "folio.thumbnails", qos: .userInitiated)

    func image(for url: URL, completion: @escaping (NSImage) -> Void) -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(mtime)" as NSString
        if let img = cache.object(forKey: key) { return img }
        queue.async { [cache] in
            guard let doc = PDFDocument(url: url), !doc.isLocked, let page = doc.page(at: 0) else { return }
            let img = page.thumbnail(of: NSSize(width: 120, height: 160), for: .cropBox)
            DispatchQueue.main.async {
                cache.setObject(img, forKey: key)
                completion(img)
            }
        }
        return nil
    }
}
