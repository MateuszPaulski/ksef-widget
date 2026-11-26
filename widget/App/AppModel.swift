import Foundation
import KsefCore
import os
import WidgetKit

let logger = Logger(subsystem: "local.ksef-daily-fetch.app", category: "app")

enum SettingsState {
    case missing, broken
    case ready(Settings)

    var settings: Settings? {
        if case .ready(let settings) = self { settings } else { nil }
    }

    var isConfigured: Bool {
        if case .missing = self { false } else { true }
    }
}

private struct SetupError: LocalizedError {
    let errorDescription: String?
}

/// State shared by the menu, the scheduler and the settings window.
@MainActor
final class AppModel {
    let paths = AppPaths.current
    let gate = RunGate()
    var notificationsAllowed: Bool?
    private(set) var lastRunEnd: Date?
    private var keyPassword: String?
    private let transport = URLSessionTransport()

    var settingsState: SettingsState {
        do {
            return try SettingsFile.load(paths.settings).map(SettingsState.ready) ?? .missing
        } catch {
            return .broken
        }
    }

    func cache(password: String) {
        keyPassword = password
    }

    /// After a credential change the Keychain, not memory, is the source of truth.
    func forgetPassword() {
        keyPassword = nil
    }

    func password() async throws -> String {
        if let keyPassword { return keyPassword }
        // SecItemCopyMatching blocks, and may wait for the owner at a Keychain prompt.
        let read = try await Task.detached { try KeychainSecretStore().readKeyPassword() }.value
        keyPassword = read
        return read
    }

    /// Must run inside the gate. A dry run lists the first window and writes nothing.
    func perform(_ settings: Settings, dryRun: Bool) async throws -> RunSummary {
        let options = RunOptions(
            settings: settings, certificateURL: paths.certificate, keyURL: paths.key, keyPassword: try await password(),
            transport: transport, sleep: { try? await Task.sleep(for: .milliseconds($0)) }, now: { Date() },
            notify: { try await Notifier.post($0, $1) }, log: { logger.notice("\($0, privacy: .public)") },
            snapshotURL: paths.snapshot, dryRun: dryRun
        )
        return await run(options)
    }

    /// Must run inside the gate.
    func fetch(trigger: String) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "KSeF fetch")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        var status = "setup-failed"
        var saved = 0
        do {
            guard let settings = try SettingsFile.load(paths.settings) else {
                throw SetupError(errorDescription: menuStatusLine(.notConfigured))
            }
            let summary = try await perform(settings, dryRun: false)
            status = summary.status.rawValue
            saved = summary.saved.count
        } catch {
            await reportSetupFailure(
                errorMessage(error), snapshotURL: paths.snapshot, now: Date(), notify: { try await Notifier.post($0, $1) },
                log: { logger.notice("\($0, privacy: .public)") }
            )
        }
        lastRunEnd = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "KsefInvoices")
        logger.notice("run finished trigger=\(trigger, privacy: .public) status=\(status, privacy: .public) saved=\(saved)")
    }
}
