import SwiftUI
import WidgetKit

@main
struct KsefWidgetBundle: WidgetBundle {
    var body: some Widget {
        InvoicesWidget()
    }
}

struct InvoicesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KsefInvoices", provider: Provider()) { entry in
            EntryView(entry: entry)
        }
        .configurationDisplayName("Faktury KSeF")
        .description("Najnowsze faktury zakupowe z KSeF.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let result: Result<Snapshot, SnapshotLoadError>
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, result: .failure(.missing))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, result: SnapshotFile.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let result = SnapshotFile.load()
        let entries = WidgetModel.timelineDates(result, now: now).map { Entry(date: $0, result: result) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct EntryView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        InvoiceListView(
            model: WidgetModel.make(entry.result, now: entry.date),
            isLarge: family == .systemLarge,
            linksEnabled: true
        )
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
