import AppKit

struct MenuContent {
    let statusLine: String
    let showsNotificationWarning: Bool
    let configured: Bool
    let canFetch: Bool
    let showsWarningIcon: Bool
}

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let content: () -> MenuContent
    private let fetchNow: () -> Void
    private let openSettings: () -> Void
    private let openInvoiceFolder: () -> Void

    init(
        content: @escaping () -> MenuContent, fetchNow: @escaping () -> Void, openSettings: @escaping () -> Void,
        openInvoiceFolder: @escaping () -> Void
    ) {
        self.content = content
        self.fetchNow = fetchNow
        self.openSettings = openSettings
        self.openInvoiceFolder = openInvoiceFolder
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let symbol = content().showsWarningIcon ? "exclamationmark.triangle" : "doc.text"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "KSeF")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let content = content()
        menu.removeAllItems()
        menu.addItem(disabled(content.statusLine))
        if content.showsNotificationWarning {
            menu.addItem(disabled("Powiadomienia są wyłączone — włącz je w Ustawieniach systemowych"))
        }
        menu.addItem(.separator())
        let fetch = item("Pobierz teraz", #selector(fetchNowClicked))
        fetch.isEnabled = content.canFetch
        menu.addItem(fetch)
        menu.addItem(item("Ustawienia…", #selector(openSettingsClicked), key: ","))
        let folder = item("Otwórz folder faktur", #selector(openFolderClicked))
        folder.isEnabled = content.configured
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Zakończ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        refreshIcon()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func fetchNowClicked() { fetchNow() }
    @objc private func openSettingsClicked() { openSettings() }
    @objc private func openFolderClicked() { openInvoiceFolder() }
}
