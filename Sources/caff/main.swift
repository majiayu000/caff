import AppKit
import Darwin

if CommandLine.arguments.count > 1 {
    do {
        try CaffCommandLineController().run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(0)
    } catch {
        fputs("Caff CLI error: \(error)\n", stderr)
        exit(2)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
