import SwiftUI
import UIKit

/// The app's price in each chosen storefront, converted for comparison.
struct RegionPriceView: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    @State private var prices: [RegionPrice] = []
    @State private var rates: ExchangeRates?
    @State private var loading = true
    @State private var showSpinner = false
    @State private var editingRegions = false
    @State private var inApps: [String: [InAppPrice]] = [:]
    @State private var inAppsLoading = false
    @State private var inAppNames: [String: String] = [:]
    /// Bumped to reload: on opening, after the region list was edited, on pull to refresh.
    @State private var reload = 0
    /// The latest load; an older one that finishes late changes nothing.
    @State private var generation = 0
    @State private var loadedRegions: [String] = []
    static let currencies = ["CNY", "HKD", "TWD", "USD", "JPY", "KRW", "EUR", "GBP", "SGD", "AUD", "CAD", "TRY"]

    private var base: String { store.settings.baseCurrency }
    private func cheapest(in sorted: [RegionPrice]) -> String? {
        sorted.first { item in item.price.map { $0 > 0 && rates?.convert($0, from: item.currency) != nil } == true }?.country
    }

    var body: some View {
        let sorted = PriceComparison.sorted(prices, rates: rates)
        let cheapest = cheapest(in: sorted)
        return List {
            Section {
                if prices.isEmpty && loading {
                    ForEach(0..<min(4, max(1, store.settings.priceRegions.count)), id: \.self) { _ in RegionPriceSkeleton() }
                } else if prices.isEmpty {
                    Text("Can't read prices right now. Pull to retry.").foregroundStyle(.secondary)
                }
                ForEach(sorted) { item in
                    RegionPriceRow(item: item, rates: rates, cheapest: item.country == cheapest)
                }
            } header: {
                HStack {
                    Text("App price")
                    Spacer()
                    if showSpinner { ProgressView().controlSize(.small) }
                }
            } footer: { Text(footnote) }
            inAppSection
        }
        .navigationTitle("Regional prices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Menu {
                    Picker("Convert to", selection: $store.settings.baseCurrency) {
                        ForEach(Self.currencies, id: \.self) { Text(currencyName($0)).tag($0) }
                    }
                    Button("Choose regions to compare", systemImage: "globe") { editingRegions = true }
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Price comparison")
            }
        }
        // Reloads once the region list is closed, not on every tap in it.
        .sheet(isPresented: $editingRegions, onDismiss: {
            if store.settings.priceRegions != loadedRegions { reload += 1 }
        }) {
            NavigationStack { RegionSelectionView(selection: $store.settings.priceRegions) }
        }
        .revealAfterDelay(loading, into: $showSpinner)
        .task(id: reload) { await load() }
        .task(id: base) { rates = await ExchangeRates.load(base: base) }
        .refreshable { await load() }
    }

    /// Listed storefronts whose pages this network could not open.
    private var blocked: [String] {
        prices.filter { $0.listing != nil && inApps[$0.country] == nil && InAppPriceService.redirected.contains(app.id + "|" + $0.country) }
            .map(\.country)
    }

    private var groups: [InAppGroup] {
        let regions = prices.compactMap { item -> (country: String, currency: String, items: [InAppPrice])? in
            guard let items = inApps[item.country], !items.isEmpty else { return nil }
            return (item.country, item.currency, items)
        }
        return InAppPriceService.groups(regions, rates: rates)
    }

    @ViewBuilder private var inAppSection: some View {
        let list = groups
        if !list.isEmpty || inAppsLoading || !prices.isEmpty {
            Section {
                if list.isEmpty {
                    if inAppsLoading {
                        HStack(spacing: 10) { ProgressView(); Text("Reading in-app purchases…").foregroundStyle(.secondary) }
                    } else {
                        Text(blocked.isEmpty || !inApps.isEmpty ? (inApps.isEmpty ? "Can't read in-app purchases right now. Pull to retry." : "The App Store doesn't list any in-app purchases for this app.")
                             : "No in-app purchases were found.")
                            .foregroundStyle(.secondary)

                    }
                }
                ForEach(list) { group in InAppGroupRow(group: group, rates: rates, name: inAppNames[group.name] ?? group.name) }
                if !blocked.isEmpty && !inAppsLoading {
                    Label {
                        Text("On this network, \(blocked.map { StoreRegions.name($0) }.joined(separator: AppText.text(", "))) App Store pages redirect to the China storefront, so in-app prices for those regions cannot be read. Route apps.apple.com through your proxy and pull to refresh.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("In-app purchases")
                    Spacer()
                    if inAppsLoading && !list.isEmpty { ProgressView().controlSize(.small) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !list.isEmpty {
                        Text("Each App Store storefront lists up to 10 popular in-app purchases. Purchases with the same name are grouped by price, usually monthly, yearly and other terms.")
                    }
                }
            }
        }
    }

    private var footnote: String {
        var lines = [AppText.text("Converted to currencyName(base), lowest first.")]
        if let rates {
            lines.append(AppText.text("Mid-market reference rate as of rates.updated.formatted(date: .abbreviated, time: .omitted); your card issuer sets the amount charged."))
        } else if !loading {
            lines.append(AppText.text("Exchange rates aren't available, so only local prices are shown."))
        }
        if prices.contains(where: { StoreRegions.taxExcluded.contains($0.country) && $0.listing != nil }) {
            lines.append(AppText.text("Prices in the US and Canada exclude sales tax."))
        }
        return lines.joined(separator: "\n")
    }

    private func currencyName(_ code: String) -> String {
        (AppText.locale.localizedString(forCurrencyCode: code) ?? code) + AppText.text(" (code)")
    }

    private func load() async {
        generation += 1
        let current = generation
        let regions = store.settings.priceRegions
        loadedRegions = regions
        loading = true
        let found = await PriceComparison.regionPrices(appID: app.id, countries: regions)
        guard current == generation else { return }
        withAnimation(.easeOut(duration: 0.2)) { prices = found }
        loading = false
        // In-app purchases come from each listed storefront's product page.
        inAppsLoading = true
        let listed = found.filter { $0.listing != nil }.map(\.country)
        let pages = await InAppPriceService.fetch(appID: app.id, countries: listed)
        guard current == generation else { return }
        withAnimation(.easeOut(duration: 0.2)) { inApps = pages }
        inAppsLoading = false
        // Matching uses the English names; show them in the system language.
        let names = await InAppPriceService.localizedNames(appID: app.id, english: pages)
        guard current == generation, !names.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { inAppNames = names }
    }
}

struct RegionPriceRow: View {
    let item: RegionPrice
    let rates: ExchangeRates?
    var cheapest = false
    var body: some View {
        HStack(spacing: 12) {
            Text(StoreRegions.flag(item.country)).font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(StoreRegions.name(item.country)).font(.body)
                    if cheapest { TagBadge(text: "Lowest", tint: .green) }
                }
                Text(local).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let converted {
                Text(converted).font(.body.monospacedDigit().weight(.medium))
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var local: String {
        guard item.listing != nil else { return AppText.text("Not sold in this region") }
        guard let price = item.price else { return AppText.text("Price unknown") }
        let text = WatchService.format(price, currency: item.currency)
        return StoreRegions.taxExcluded.contains(item.country) && price > 0 ? text + AppText.text(" (excl. tax)") : text
    }
    private var converted: String? {
        guard let price = item.price, price > 0, let rates, item.currency != rates.base,
              let value = rates.convert(price, from: item.currency) else { return nil }
        return "≈ " + WatchService.format(value, currency: rates.base)
    }
}

struct InAppGroupRow: View {
    let group: InAppGroup
    let rates: ExchangeRates?
    /// The purchase's name in the system language when known.
    var name: String
    var body: some View {
        DisclosureGroup {
            ForEach(Array(group.entries.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 12) {
                    Text(StoreRegions.flag(entry.country)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(StoreRegions.name(entry.country))
                            if index == 0 && group.entries.count > 1 && converted(entry) != nil { TagBadge(text: "Lowest", tint: .green) }
                        }
                        Text(entry.item.text).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let converted = converted(entry) { Text(converted).font(.body.monospacedDigit()) }
                }
                .accessibilityElement(children: .combine)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary).lineLimit(2)
                    Text(group.tiers > 1 ? "Tier group.tier + 1 · group.entries.count regions" : "group.entries.count regions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let cheapest = group.entries.first {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(converted(cheapest) ?? cheapest.item.text).font(.body.monospacedDigit().weight(.medium)).foregroundStyle(.primary)
                        Text(StoreRegions.flag(cheapest.country) + " " + StoreRegions.name(cheapest.country))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func converted(_ entry: InAppGroup.Entry) -> String? {
        guard let price = entry.item.price, let rates, let value = rates.convert(price, from: entry.currency) else { return nil }
        return (entry.currency == rates.base ? "" : "≈ ") + WatchService.format(value, currency: rates.base)
    }
}

private struct RegionPriceSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(.tertiarySystemFill)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 90, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 60, height: 12)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// Picks the storefronts to compare; chosen ones first.
struct RegionSelectionView: View {
    @Binding var selection: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var others: [String] {
        StoreRegions.byName().filter { !selection.contains($0) }
            .filter { search.isEmpty || StoreRegions.name($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    ForEach(selection, id: \.self) { code in row(code, selected: true) }
                        .onMove { selection.move(fromOffsets: $0, toOffset: $1) }
                } header: { Text("selection.count selected") } footer: {
                    Text("Followed apps also record price changes in these regions.")
                }
            }
            Section(search.isEmpty ? "Other regions" : "Results") {
                ForEach(search.isEmpty ? others : selection.filter { StoreRegions.name($0).localizedCaseInsensitiveContains(search) } + others,
                        id: \.self) { code in row(code, selected: selection.contains(code)) }
            }
        }
        .searchable(text: $search, prompt: "Search regions")
        .navigationTitle("Compare regions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func row(_ code: String, selected: Bool) -> some View {
        Button {
            if selected {
                guard selection.count > 1 else { return }
                selection.removeAll { $0 == code }
            } else {
                selection.append(code)
            }
        } label: {
            HStack(spacing: 12) {
                Text(StoreRegions.flag(code)).accessibilityHidden(true)
                Text(StoreRegions.name(code)).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
