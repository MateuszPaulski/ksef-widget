import AppKit
import KsefCore
import Observation
import SwiftUI

private extension SettingsMessage {
    static let busy = SettingsMessage(text: "Trwa pobieranie — spróbuj za chwilę.", isError: true)

    static func failure(_ error: Error) -> SettingsMessage { SettingsMessage(text: "Błąd: \(errorMessage(error))", isError: true) }
}

@MainActor @Observable
private final class SettingsModel {
    var form: SettingsForm
    var busy = false

    init(form: SettingsForm) { self.form = form }
}

private struct SettingsRoot: View {
    @Bindable var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsView(form: $model.form, busy: model.busy, actions: actions)
    }
}

/// The settings window and everything its buttons do.
@MainActor
final class SettingsWindowController {
    private let app: AppModel
    private let didChange: () -> Void
    private let didVerify: () -> Void
    private var window: NSWindow?
    private var model: SettingsModel?
    private var certificate: URL?
    private var key: URL?

    init(app: AppModel, didChange: @escaping () -> Void, didVerify: @escaping () -> Void) {
        self.app = app
        self.didChange = didChange
        self.didVerify = didVerify
    }

    func show() {
        if let window, let model {
            if !window.isVisible {
                resetFiles()
                model.form = makeForm()
            }
        } else {
            build()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        refreshNotificationStatus()
    }

    private func build() {
        let model = SettingsModel(form: makeForm())
        let actions = SettingsActions(
            chooseCertificate: { [weak self] in self?.chooseFile(certificate: true) },
            chooseKey: { [weak self] in self?.chooseFile(certificate: false) },
            chooseFolder: { [weak self] in self?.chooseFolder() },
            save: { [weak self] in self?.save() },
            check: { [weak self] in self?.check() },
            testNotification: { [weak self] in self?.testNotification() },
            openLoginItems: { LoginItem.openSystemSettings() },
            setStartAtLogin: { [weak self] in self?.setStartAtLogin($0) }
        )
        let hosting = NSHostingController(rootView: SettingsRoot(model: model, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ustawienia KSeF"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.model = model
        self.window = window
    }

    private func resetFiles() {
        certificate = nil
        key = nil
    }

    private func makeForm() -> SettingsForm {
        var message: SettingsMessage?
        var settings: KsefCore.Settings?
        do {
            settings = try SettingsFile.load(app.paths.settings)
        } catch {
            message = .failure(error)
        }
        let loginStatus = LoginItem.status
        return SettingsForm(
            nip: settings?.nip ?? "", environment: settings?.environment ?? .prod,
            startDate: startDate(fromText: settings?.startDate ?? defaultStartDateText(now: Date())) ?? Date(),
            dataDir: settings?.dataDir ?? app.paths.defaultDataDir.path, certificateName: nil, keyName: nil, password: "",
            hasStoredCredentials: storedCredentialsExist(), startAtLogin: loginStatus == .enabled,
            loginNeedsApproval: loginStatus == .requiresApproval,
            notificationsAllowed: settings == nil ? nil : app.notificationsAllowed,
            legacyAgent: LegacyLaunchAgent.isInstalled(app.paths), message: message
        )
    }

    private func storedCredentialsExist() -> Bool {
        FileManager.default.fileExists(atPath: app.paths.certificate.path) && FileManager.default.fileExists(atPath: app.paths.key.path)
    }

    private func refreshNotificationStatus() {
        guard let model, case .ready = app.settingsState else { return }
        Task {
            let allowed = await Notifier.isAuthorized()
            app.notificationsAllowed = allowed
            model.form.notificationsAllowed = allowed
            didChange()
        }
    }

    private func chooseFile(certificate isCertificate: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = isCertificate ? "Wybierz plik certyfikatu (.crt)" : "Wybierz plik klucza prywatnego (.key)"
        guard panel.runModal() == .OK, let url = panel.url, let model else { return }
        if isCertificate {
            certificate = url
            model.form.certificateName = url.lastPathComponent
        } else {
            key = url
            model.form.keyName = url.lastPathComponent
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let model else { return }
        model.form.dataDir = url.path
    }

    private func save() {
        guard let model else { return }
        let form = model.form
        let draft = SettingsDraft(
            nip: form.nip.trimmingCharacters(in: .whitespaces), environment: form.environment, startDate: startDateText(form.startDate),
            dataDir: form.dataDir, certificate: certificate, key: key, password: form.password
        )
        let includesCredentials = draft.includesCredentials
        model.busy = true
        Task {
            var message = SettingsMessage.busy
            _ = await app.gate.runIfIdle {
                message = await performSave(draft, model: model)
                if includesCredentials { app.forgetPassword() }
            }
            model.form.message = message
            model.busy = false
            didChange()
        }
    }

    private func performSave(_ draft: SettingsDraft, model: SettingsModel) async -> SettingsMessage {
        let paths = app.paths
        let previous = (try? SettingsFile.load(paths.settings)) ?? nil
        do {
            // The Keychain write blocks, and may wait for the owner at a prompt.
            let saved = try await Task.detached {
                try saveSettings(draft, previous: previous, paths: paths, secrets: KeychainSecretStore(), today: Date())
            }.value
            do {
                try await Notifier.requestAuthorizationIfNeeded()
            } catch {
                logger.notice("notification authorization failed: \(errorMessage(error), privacy: .public)")
            }
            app.notificationsAllowed = await Notifier.isAuthorized()
            resetFiles()
            model.form.certificateName = nil
            model.form.keyName = nil
            model.form.password = ""
            model.form.hasStoredCredentials = true
            model.form.notificationsAllowed = app.notificationsAllowed
            return SettingsMessage(text: saved.verified ? "Zapisano." : "Zapisano. Teraz naciśnij „Sprawdź połączenie”.", isError: false)
        } catch {
            return .failure(error)
        }
    }

    private func check() {
        guard let model, model.form.hasStoredCredentials else { return }
        model.busy = true
        model.form.message = SettingsMessage(text: "Sprawdzanie…", isError: false)
        Task {
            var message = SettingsMessage.busy
            var verified = false
            _ = await app.gate.runIfIdle {
                (message, verified) = await runCheck()
            }
            model.form.message = message
            model.busy = false
            didChange()
            if verified { didVerify() }
        }
    }

    private func runCheck() async -> (SettingsMessage, verified: Bool) {
        do {
            guard var settings = try SettingsFile.load(app.paths.settings) else {
                return (SettingsMessage(text: "Błąd: \(menuStatusLine(.notConfigured))", isError: true), false)
            }
            let outcome = connectionCheckResult(try await app.perform(settings, dryRun: true))
            if !outcome.isError {
                try adoptDataFolder(settings)
                settings.verified = true
                try SettingsFile.save(settings, to: app.paths.settings)
            }
            return (SettingsMessage(text: outcome.text, isError: outcome.isError), !outcome.isError)
        } catch {
            return (.failure(error), false)
        }
    }

    private func testNotification() {
        guard let model else { return }
        model.busy = true
        Task {
            do {
                try await Notifier.requestAuthorizationIfNeeded()
                try await Notifier.post("KSeF: test powiadomienia", "Powiadomienia działają.")
                model.form.message = SettingsMessage(text: "Wysłano testowe powiadomienie.", isError: false)
            } catch {
                model.form.message = .failure(error)
            }
            app.notificationsAllowed = await Notifier.isAuthorized()
            model.form.notificationsAllowed = app.notificationsAllowed
            model.busy = false
            didChange()
        }
    }

    private func setStartAtLogin(_ enabled: Bool) {
        guard let model else { return }
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            model.form.message = .failure(error)
        }
        let loginStatus = LoginItem.status
        model.form.startAtLogin = loginStatus == .enabled
        model.form.loginNeedsApproval = loginStatus == .requiresApproval
    }
}
