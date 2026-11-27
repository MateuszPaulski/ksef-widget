import SwiftUI

// Every dynamic string is Text(verbatim:): seller names are attacker-controlled and must never be read as Markdown.
// Only semantic styles are used, so the text follows the widget background in light and dark appearance.
struct InvoiceListView: View {
    let model: WidgetModel
    let isLarge: Bool
    let linksEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: model.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let newToday = model.newToday {
                    Text(verbatim: newToday)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let banner = model.banner {
                Text(verbatim: banner.text)
                    .font(.caption)
                    .foregroundStyle(banner.tone == .error ? Color.red : Color.orange)
                    .lineLimit(2)
            }
            ForEach(model.rows.prefix(model.rowLimit(isLarge: isLarge))) { row in
                if linksEnabled, let url = row.url {
                    Link(destination: url) { rowContent(row) }
                } else {
                    rowContent(row)
                }
            }
            if let emptyText = model.emptyText {
                Text(verbatim: emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let footer = model.footer {
                Divider()
                Text(verbatim: footer.text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(footer.warning ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func rowContent(_ row: WidgetModel.Row) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: row.seller)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: row.amount)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Text(verbatim: row.date)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.callout)
    }
}
