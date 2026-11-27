import Foundation

struct WidgetModel: Equatable {
    enum Tone: Equatable { case warning, error }

    struct Banner: Equatable {
        let text: String
        let tone: Tone
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let seller: String
        let amount: String
        let date: String
        let url: URL?
    }

    struct Footer: Equatable {
        let text: String
        let warning: Bool
    }

    let title: String
    let newToday: String?
    let banner: Banner?
    let rows: [Row]
    let emptyText: String?
    let footer: Footer?

    static let staleAfter: TimeInterval = 3 * 3600

    func rowLimit(isLarge: Bool) -> Int {
        isLarge ? 8 : 3 - (banner == nil ? 0 : 1) - (footer == nil ? 0 : 1)
    }

    static func make(_ result: Result<Snapshot, SnapshotLoadError>, now: Date) -> WidgetModel {
        switch result {
        case .failure(let error):
            let text: String
            switch error {
            case .missing: text = "Brak danych — pobieranie jeszcze nie zapisało stanu widżetu."
            case .unreadable(let message): text = "Nie można odczytać danych widżetu: \(message)"
            }
            return WidgetModel(title: "KSeF", newToday: nil, banner: Banner(text: text, tone: .error), rows: [], emptyText: nil, footer: nil)

        case .success(let snapshot):
            let updated = warsaw.dateComponents([.day, .month, .hour, .minute], from: snapshot.updatedAt)
            let updatedTime = clock(updated)
            let banner: Banner?
            if now >= snapshot.updatedAt.addingTimeInterval(staleAfter) {
                banner = Banner(text: "Dane nieaktualne — ostatnia aktualizacja \(dayMonth(updated)) \(updatedTime)", tone: .error)
            } else if snapshot.status == .failed {
                banner = Banner(text: "Błąd pobierania: \(snapshot.reason ?? "")", tone: .error)
            } else if snapshot.status == .partial {
                banner = Banner(text: "Pobrano częściowo — reszta przy następnym uruchomieniu.", tone: .warning)
            } else {
                banner = nil
            }
            return WidgetModel(
                title: "KSeF · zaktualizowano \(updatedTime)",
                newToday: snapshot.savedToday > 0 && snapshot.today == warsawDay(now) ? newTodayLabel(snapshot.savedToday) : nil,
                banner: banner,
                rows: snapshot.invoices.map(row),
                emptyText: snapshot.invoices.isEmpty && snapshot.status != .failed ? "Brak zapisanych faktur." : nil,
                footer: snapshot.yearSummary.map { Footer(text: $0.text, warning: $0.warning) }
            )
        }
    }

    // The current entry, the moment the data turns stale, and the next Warsaw midnight, so the stale banner
    // and the "dziś" count change even when macOS delays the next reload.
    static func timelineDates(_ result: Result<Snapshot, SnapshotLoadError>, now: Date) -> [Date] {
        var dates = [now]
        if case .success(let snapshot) = result {
            let stale = snapshot.updatedAt.addingTimeInterval(staleAfter)
            if stale > now { dates.append(stale) }
        }
        if let midnight = warsaw.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) {
            dates.append(midnight)
        }
        return dates.sorted()
    }

    private static let warsaw: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    private static func clock(_ parts: DateComponents) -> String {
        String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func dayMonth(_ parts: DateComponents) -> String {
        String(format: "%02d.%02d", parts.day ?? 0, parts.month ?? 0)
    }

    private static func warsawDay(_ date: Date) -> String {
        let parts = warsaw.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func row(_ invoice: Snapshot.Invoice) -> Row {
        let day = invoice.issueDate.split(separator: "-")
        return Row(
            id: invoice.ksefNumber,
            seller: invoice.seller,
            amount: invoice.amount,
            date: day.count == 3 ? "\(day[2]).\(day[1])" : invoice.issueDate,
            url: URL(string: invoice.viewUrl).flatMap { KsefLink.isAllowed($0) ? $0 : nil }
        )
    }
}

func newTodayLabel(_ count: Int) -> String {
    if count == 1 { return "1 nowa dziś" }
    let lastDigit = count % 10
    let lastTwo = count % 100
    if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) { return "\(count) nowe dziś" }
    return "\(count) nowych dziś"
}
