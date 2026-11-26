import Foundation

private let maxReasonCharacters = 80

public struct SnapshotStatus: Equatable, Sendable {
    public let updatedAt: Date
    public let status: RunStatus
    public let reason: String?
}

/// Nil for a missing, unreadable or unrecognised file.
public func readSnapshotStatus(_ url: URL) -> SnapshotStatus? {
    guard let object = readSnapshotObject(url),
          let updatedAt = object["updatedAt"] as? String, let millis = KsefTime.millis(updatedAt),
          let status = (object["status"] as? String).flatMap(RunStatus.init(rawValue:))
    else { return nil }
    return SnapshotStatus(updatedAt: KsefTime.date(millis: millis), status: status, reason: object["reason"] as? String)
}

public enum MenuState: Equatable, Sendable {
    case running, legacyAgent, notConfigured, notVerified
    case idle(SnapshotStatus?)
}

public func menuStatusLine(_ state: MenuState) -> String {
    switch state {
    case .running: "Pobieranie w toku…"
    case .legacyAgent: "Wstrzymane: zainstalowane jest stare zadanie launchd"
    case .notConfigured: "Nie skonfigurowano — otwórz Ustawienia…"
    case .notVerified: "Sprawdź połączenie w Ustawieniach, aby zacząć pobieranie"
    case .idle(nil): "Jeszcze nie pobierano"
    case .idle(let status?): "Ostatnio \(warsawStamp(status.updatedAt)) — \(outcome(status))"
    }
}

private func outcome(_ status: SnapshotStatus) -> String {
    switch status.status {
    case .complete: return "zakończone"
    case .partial: return "pobrano częściowo"
    case .failed:
        guard let reason = status.reason else { return "błąd" }
        return "błąd: " + (reason.count > maxReasonCharacters ? String(reason.prefix(maxReasonCharacters - 1)) + "…" : reason)
    }
}

/// `DD.MM HH:mm` in Warsaw.
private func warsawStamp(_ date: Date) -> String {
    let day = warsawDay(date)
    return "\(day.suffix(2)).\(day.dropFirst(5).prefix(2)) \(warsawTime(date).prefix(5))"
}
