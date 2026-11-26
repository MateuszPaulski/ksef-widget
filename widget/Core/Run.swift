import Foundation

public struct RunOptions: Sendable {
    public var settings: Settings
    public var certificateURL: URL
    public var keyURL: URL
    public var keyPassword: String
    public var transport: any HTTPTransport
    public var sleep: @Sendable (Int) async -> Void  // milliseconds
    public var now: @Sendable () -> Date
    public var notify: @Sendable (String, String) async throws -> Void
    public var log: @Sendable (String) -> Void
    public var snapshotURL: URL
    public var dryRun: Bool

    public init(
        settings: Settings, certificateURL: URL, keyURL: URL, keyPassword: String, transport: any HTTPTransport,
        sleep: @escaping @Sendable (Int) async -> Void, now: @escaping @Sendable () -> Date,
        notify: @escaping @Sendable (String, String) async throws -> Void, log: @escaping @Sendable (String) -> Void,
        snapshotURL: URL, dryRun: Bool = false
    ) {
        self.settings = settings
        self.certificateURL = certificateURL
        self.keyURL = keyURL
        self.keyPassword = keyPassword
        self.transport = transport
        self.sleep = sleep
        self.now = now
        self.notify = notify
        self.log = log
        self.snapshotURL = snapshotURL
        self.dryRun = dryRun
    }
}

/// Never throws: every failure ends up in the returned summary, the report, the notification and the snapshot.
public func run(_ options: RunOptions) async -> RunSummary {
    let settings = options.settings
    let now = options.now
    let log = options.log
    let dataDir = URL(fileURLWithPath: settings.dataDir)
    let startedAt = now()
    var saved: [InvoiceMetadata] = []
    var summary: RunSummary

    do {
        let hasMarker = try checkDataFolder(dataDir, settings: settings)
        if !hasMarker && !options.dryRun { try writeDataFolderMarker(dataDir, settings: settings) }
        let credentials = try loadCredentials(certificateURL: options.certificateURL, keyURL: options.keyURL, password: options.keyPassword)
        let store = try Store.open(dataDir: dataDir, now: now)
        let http = KsefHTTP(apiBase: settings.environment.apiBase, transport: options.transport, sleep: options.sleep)
        let accessToken = try await authenticate(
            http: http, credentials: credentials, nip: settings.nip, environment: settings.environment, now: now, sleep: options.sleep
        )
        let query: Query = { window, pageOffset in
            try await queryMetadata(http: http, token: accessToken.token, window: window, pageOffset: pageOffset)
        }
        let from = store.checkpoint ?? "\(settings.startDate)T00:00:00Z"

        if options.dryRun {
            let (invoices, _) = try await listWindow(query, nextWindow(from: from, now: now()))
            let notSaved = invoices.filter { !store.has($0.ksefNumber) }.count
            log("dry run: \(invoices.count) invoices in the first window, \(notSaved) not yet saved")
            return RunSummary(
                startedAt: startedAt, status: .complete, reason: nil, failureKey: nil, saved: [],
                checked: DryRunCounts(listed: invoices.count, notSaved: notSaved)
            )
        }

        let outcome = try await syncInvoices(SyncDeps(
            from: from,
            store: store,
            query: query,
            download: { try await downloadInvoice(http: http, token: accessToken.token, ksefNumber: $0) },
            tokenValidUntil: accessToken.validUntil,
            now: now,
            sleep: options.sleep,
            onSaved: { saved.append($0) }
        ))
        let (status, reason): (RunStatus, String?) = switch outcome {
        case .complete: (.complete, nil)
        case .partial(let reason): (.partial, reason)
        }
        summary = RunSummary(startedAt: startedAt, status: status, reason: reason, failureKey: nil, saved: saved, checked: nil)
    } catch {
        // An API error message embeds volatile response text; the status alone identifies the failure.
        let failureKey = (error as? KsefApiError).map { "KSeF \($0.status)" } ?? errorMessage(error)
        summary = RunSummary(startedAt: startedAt, status: .failed, reason: errorMessage(error), failureKey: failureKey, saved: saved, checked: nil)
    }

    if options.dryRun { return summary }

    // A lasting failure would otherwise notify at every hourly run: stay quiet when the snapshot on disk already
    // holds the same failure from today. New invoices saved by this run are always announced.
    let finishedAt = now()
    let repeatedFailure = summary.status == .failed && summary.saved.isEmpty
        && isRepeatedFailure(summary.failureKey, snapshotURL: options.snapshotURL, now: finishedAt)

    if summary.status != .complete || !summary.saved.isEmpty {
        do {
            try appendReport(dataDir: dataDir, day: warsawDay(startedAt), section: formatReportSection(summary, settings.environment))
        } catch {
            log("could not write the report: \(errorMessage(error))")
        }
        if repeatedFailure { log("repeated failure, notification skipped") }
        if !repeatedFailure, let notification = formatNotification(summary) {
            await notifyLogging(notification.title, notification.message, notify: options.notify, log: log)
        }
    }

    var invoices: [WidgetInvoice] = []
    do {
        invoices = try readIndex(dataDir: dataDir).map { widgetInvoice($0, settings.environment) }
    } catch {
        log("could not read the index for the widget: \(errorMessage(error))")
    }
    writeSnapshotLogging(
        buildSnapshot(status: summary.status, reason: summary.reason, failureKey: summary.failureKey, invoices: invoices, now: finishedAt),
        to: options.snapshotURL, log: log
    )
    log("status=\(summary.status.rawValue) saved=\(summary.saved.count)\(summary.reason.map { " reason=\($0)" } ?? "")")
    return summary
}

/// For a problem found before a run can start (settings, credential files, Keychain): the same notify-once-a-day
/// rule and a failed snapshot, so the widget does not show stale data.
public func reportSetupFailure(
    _ message: String, snapshotURL: URL, now: Date,
    notify: @Sendable (String, String) async throws -> Void, log: @Sendable (String) -> Void
) async {
    log("setup failed: \(message)")
    if isRepeatedFailure(message, snapshotURL: snapshotURL, now: now) {
        log("repeated failure, notification skipped")
    } else {
        await notifyLogging("KSeF: błąd pobierania faktur", message, notify: notify, log: log)
    }
    writeSnapshotLogging(
        buildSnapshot(status: .failed, reason: message, failureKey: message, invoices: [], now: now), to: snapshotURL, log: log
    )
}

private func isRepeatedFailure(_ failureKey: String?, snapshotURL: URL, now: Date) -> Bool {
    guard let previous = readPreviousFailure(snapshotURL) else { return false }
    return previous.failureKey == failureKey && previous.today == warsawDay(now)
}

private func notifyLogging(
    _ title: String, _ message: String, notify: @Sendable (String, String) async throws -> Void, log: @Sendable (String) -> Void
) async {
    do {
        try await notify(title, message)
    } catch {
        log("could not show the notification: \(errorMessage(error))")
    }
}

private func writeSnapshotLogging(_ snapshot: WidgetSnapshot, to url: URL, log: @Sendable (String) -> Void) {
    do {
        try writeSnapshot(snapshot, to: url)
    } catch {
        log("could not write the widget snapshot: \(errorMessage(error))")
    }
}
