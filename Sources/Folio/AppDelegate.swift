import AppKit

enum AppState {
    static var isQuitting = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = FolioDocumentController()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Lancée sans fichier : écran d'accueil.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSDocumentController.shared.documents.isEmpty {
                HomeWindowController.shared.show()
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { HomeWindowController.shared.show() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.isQuitting = true
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showHome(_ sender: Any?) {
        HomeWindowController.shared.show()
    }
}
