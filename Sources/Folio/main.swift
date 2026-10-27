import AppKit

// Mode auto-test (lancé par build.sh) : génère un PDF annoté, l'enregistre, le recharge et en fait un rendu.
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : FileManager.default.currentDirectoryPath + "/selftest"
    SelfTest.run(outputDir: dir)
    exit(0)
}

let app = FolioApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
