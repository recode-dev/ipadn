import SwiftUI
import Charts

extension WatchChange {
    /// A short tag for lists.
    var tag: LocalizedStringKey {
        switch self {
        case .newVersion: return "New version"
        case .priceDrop: return "Price drop"
        case .free: return "Now free"
        case .priceRise: return "Price increase"
        case .delisted: return "Removed"
        case .relisted: return "Relisted"
        }
    }
    var tint: Color {
        switch self {
        case .free, .priceDrop: return .green
        case .newVersion, .relisted: return .blue
        case .priceRise: return .secondary
        case .delisted: return .orange
        }
    }
}

/// A followed app in the list: current price and version, and the latest change.
struct WatchRow: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    var body: some View {
        let record = store.watchRecord(app.id)
        let price = record.flatMap { record in record.price.map { WatchService.format($0, currency: record.currency) } }
        let version = (record?.version).flatMap { $0.isEmpty ? nil : $0 } ?? (app.version.isEmpty ? nil : app.version)
        let subtitle = [price, version.map { "v" + $0 }].compactMap { $0 }.joined(separator: " · ")
        AppRow(app: app, subtitle: subtitle.isEmpty ? nil : subtitle, badge: badge(record))
    }
    private func badge(_ record: WatchRecord?) -> (text: LocalizedStringKey, tint: Color)? {
        guard let record else { return nil }
        if record.delisted { return app.isDelisted ? nil : (WatchChange.delisted.tag, WatchChange.delisted.tint) }
        return record.recentChange().map { ($0.tag, $0.tint) }
    }
}

/// Price changes recorded since the app was followed.
struct PriceHistorySection: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    @State private var country: String?
    /// The account's storefront, then the comparison storefronts with a record.
    private var countries: [String] {
        var list = [store.watchCountry]
        for code in store.settings.priceRegions.map({ $0.uppercased() })
        where !list.contains(code) && store.watch[WatchRecord.key(id: app.id, country: code)]?.price != nil {
            list.append(code)
        }
        return list
    }
    var body: some View {
        let shown = country.flatMap { countries.contains($0) ? $0 : nil } ?? store.watchCountry
        if countries.count > 1 {
            LabeledContent("Region") {
                Picker("Region", selection: Binding(get: { shown }, set: { country = $0 })) {
                    ForEach(countries, id: \.self) { Text(StoreRegions.flag($0) + " " + StoreRegions.name($0)).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
        }
        if let record = store.watch[WatchRecord.key(id: app.id, country: shown)] {
            if record.delisted {
                Text("Removed in this region; accounts that acquired it can still download it.").font(.subheadline).foregroundStyle(.secondary)
            }
            if let price = record.price {
                LabeledContent("Current price", value: WatchService.format(price, currency: record.currency))
            }
            if store.settings.targetPrices, let price = record.price, price > 0 {
                TargetPriceRow(record: record) { store.setWatchTarget($0, id: app.id, country: shown) }
            }
            if record.history.count > 1 {
                if let low = record.history.map(\.price).min() {
                    LabeledContent("Lowest since following", value: WatchService.format(low, currency: record.currency))
                }
                PriceHistoryChart(record: record)
                    .cardRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 20))
            } else {
                Text("Recorded since record.started.formatted(date: .abbreviated, time: .omitted). Price changes appear here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if store.watchChecking {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading prices…").foregroundStyle(.secondary)
            }
        } else {
            Text("Can't read prices right now; this retries automatically.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The price a drop has to reach before iPadn announces it; empty means any drop.
private struct TargetPriceRow: View {
    let record: WatchRecord
    let save: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Target price")
                Spacer()
                TextField("Any drop", text: $text)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .focused($focused).frame(maxWidth: 140)
                    .accessibilityIdentifier("watch.target-price")
                if focused {
                    Button("Done") { focused = false }.font(.body.weight(.semibold)).buttonStyle(.borderless)
                }
            }
            Text(record.target == nil ? "You’re notified about every price drop. Enter a price to be notified only when it drops to that price or lower."
                 : "You’re notified when the price drops to WatchService.format(record.target ?? 0, currency: record.currency) or lower, and whenever the app becomes free.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { text = Self.string(record.target) }
        .compatibleOnChange(of: record.key) { _ in text = Self.string(record.target) }
        .compatibleOnChange(of: focused) { editing in
            guard !editing else { return }
            let value = Self.value(text)
            save(value)
            text = Self.string(value)
        }
    }
    /// Accepts either decimal separator, whatever the keyboard offers.
    static func value(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "٫", with: ".")
        guard let value = Double(cleaned), value > 0, value.isFinite else { return nil }
        return value
    }
    static func string(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

struct PriceHistoryChart: View {
    let record: WatchRecord
    var body: some View {
        // Prices hold until the next change: draw steps, extended to today.
        let points = record.history + (record.history.last.map { [PricePoint(date: max(Date(), $0.date), price: $0.price)] } ?? [])
        Chart(Array(points.enumerated()), id: \.offset) { item in
            LineMark(x: .value(AppText.text("Date"), item.element.date), y: .value(AppText.text("Price"), item.element.price))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(Color.accentColor)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let price = value.as(Double.self) { Text(WatchService.format(price, currency: record.currency)) }
                }
            }
        }
        .frame(height: 160)
        .accessibilityLabel("Price history")
    }
}
