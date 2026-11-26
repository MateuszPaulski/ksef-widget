import AppKit
import os

let logger = Logger(subsystem: "local.ksef-daily-fetch.widget", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledURL = false
    private var finishedLaunching = false

    // A widget click starts the app with the row's URL. Only allow-listed KSeF links are opened. Logs never carry
    // the full URL: it contains a NIP.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledURL = true
        for url in urls {
            if KsefLink.isAllowed(url) {
                NSWorkspace.shared.open(url)
                logger.notice("opened host=\(url.host ?? "", privacy: .public)")
            } else {
                logger.notice("ignored URL scheme=\(url.scheme ?? "", privacy: .public) host=\(url.host ?? "", privacy: .public)")
            }
        }
        if finishedLaunching { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if !handledURL {
            logger.notice("default launch")
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Widżet KSeF jest zainstalowany"
            alert.informativeText = "Dodaj go: kliknij prawym przyciskiem pulpit, wybierz „Edytuj widżety…” i wyszukaj „KSeF”."
            alert.runModal()
        }
        NSApp.terminate(nil)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
