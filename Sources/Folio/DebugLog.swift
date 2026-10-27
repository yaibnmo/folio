import Foundation

/// Journal de diagnostic : actif seulement si ~/Developer/Folio/Package.swift existe (machine de développement).
enum DebugLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/Folio/folio-debug.log")
    /// Actif seulement si le fichier témoin ~/Developer/Folio/.debug contient « 1 ».
    static let enabled: Bool = {
        let marker = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/Folio/.debug")
        return (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }()

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date()) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
