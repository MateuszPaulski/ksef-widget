import AppKit
import KsefCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusMenu: StatusMenu?
    private var settingsWindow: SettingsWindowController?
    private var scheduler: NSBackgroundActivityScheduler?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let state = model.settingsState
        let configured: Bool
        let verified: Bool
        switch state {
        case .missing: (configured, verified) = (false, false)
        case .broken: (configured, verified) = (true, false)
        case .ready(let settings): (configured, verified) = (true, settings.verified)
        }
        logger.notice(
            "launch configured=\(configured) verified=\(verified) legacyAgent=\(LegacyLaunchAgent.isInstalled(self.model.paths))"
        )

        let settingsWindow = SettingsWindowController(
            app: model, didChange: { [weak self] in self?.statusMenu?.refreshIcon() }, didVerify: { [weak self] in self?.tick("verified") }
        )
        self.settingsWindow = settingsWindow
        statusMenu = StatusMenu(
            content: { [unowned self] in menuContent() },
            fetchNow: { [unowned self] in fetch("manual") },
            openSettings: { settingsWindow.show() },
            openInvoiceFolder: { [unowned self] in openInvoiceFolder() }
        )
        startScheduler()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick("wake") }
        }

        guard configured else {
            settingsWindow.show()
            return
        }
        Task { await prepareConfiguredLaunch(state) }
    }

    // A widget click starts the app with the row's URL. Only allow-listed KSeF links are opened. Logs never carry
    // the full URL: it contains a NIP.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if KsefLink.isAllowed(url) {
                NSWorkspace.shared.open(url)
                logger.notice("opened host=\(url.host ?? "", privacy: .public)")
            } else {
                logger.notice("ignored URL scheme=\(url.scheme ?? "", privacy: .public) host=\(url.host ?? "", privacy: .public)")
            }
        }
    }

    // An accessory app has no menu bar, but the settings window still needs Cmd+V for the password field.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edycja")
        edit.addItem(withTitle: "Cofnij", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Wytnij", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopiuj", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Wklej", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Zaznacz wszystko", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func startScheduler() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "local.ksef-daily-fetch.app.tick")
        scheduler.interval = 900
        scheduler.tolerance = 300
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in self?.tick("schedule") }
            completion(.finished)
        }
        self.scheduler = scheduler
    }

    // The Keychain and the invoice folder are read here, while the owner is at the Mac, so a permission prompt
    // after a rebuild never appears inside an unattended run.
    private func prepareConfiguredLaunch(_ state: SettingsState) async {
        model.notificationsAllowed = await Notifier.isAuthorized()
        var dataDir: String?
        if case .ready(let settings) = state { dataDir = settings.dataDir }
        let password = await Task.detached { () -> Result<String, Error> in
            if let dataDir {
                let url = URL(fileURLWithPath: dataDir)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                _ = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            }
            return Result { try KeychainSecretStore().readKeyPassword() }
        }.value
        switch password {
        case .success(let password): model.cache(password: password)
        case .failure(let error): logger.notice("password not read at launch: \(errorMessage(error), privacy: .public)")
        }
        tick("launch")
    }

    private func tick(_ trigger: String) {
        switch model.settingsState {
        case .missing: return
        case .ready(let settings) where !settings.verified: return
        default: break
        }
        let lastRunAt = RunSchedule.lastRunAt(snapshot: model.paths.snapshot, lastRunEnd: model.lastRunEnd)
        let due = RunSchedule.isDue(lastRunAt: lastRunAt, now: Date())
        if LegacyLaunchAgent.isInstalled(model.paths) {
            if due { logger.notice("tick trigger=\(trigger, privacy: .public) due=true blocked=legacyAgent") }
            return
        }
        guard due else { return }
        logger.notice("tick trigger=\(trigger, privacy: .public) due=true")
        fetch(trigger)
    }

    private func fetch(_ trigger: String) {
        Task {
            _ = await model.gate.runIfIdle {
                statusMenu?.refreshIcon()
                await model.fetch(trigger: trigger)
            }
            statusMenu?.refreshIcon()
        }
    }

    private func openInvoiceFolder() {
        guard case .ready(let settings) = model.settingsState else { return }
        let url = URL(fileURLWithPath: settings.dataDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func menuContent() -> MenuContent {
        let state = model.settingsState
        let legacy = LegacyLaunchAgent.isInstalled(model.paths)
        let snapshot = readSnapshotStatus(model.paths.snapshot)
        let menuState: MenuState
        var canFetch = false
        switch state {
        case .missing:
            menuState = .notConfigured
        case .broken:
            menuState = .idle(snapshot)
        case .ready(let settings):
            menuState = settings.verified ? .idle(snapshot) : .notVerified
            canFetch = settings.verified && !legacy && !model.gate.isRunning
        }
        let displayed: MenuState = model.gate.isRunning ? .running : legacy ? .legacyAgent : menuState
        var configured = true
        if case .missing = state { configured = false }
        return MenuContent(
            statusLine: menuStatusLine(displayed),
            showsNotificationWarning: configured && model.notificationsAllowed == false,
            configured: configured,
            canFetch: canFetch,
            showsWarningIcon: legacy || snapshot?.status == .failed
        )
    }
}
