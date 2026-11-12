import SwiftUI

struct DiscoverSection: View {
    @EnvironmentObject private var store: ToolStore
    var body: some View {
        if AppChart.free.feed(store.settings.store.platform) != nil {
            Section {
                ForEach(AppChart.allCases) { chart in
                    NavigationLink { ChartView(chart: chart) } label: {
                        Label(chart.title, systemImage: chart.symbol)
                    }
                    .accessibilityIdentifier("discover." + chart.rawValue)
                }
            } header: {
                HStack {
                    Text("Discover").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                }
            }
        }
    }
}

struct ChartView: View {
    @EnvironmentObject private var store: ToolStore
    @State var chart: AppChart
    @State private var genre = ChartGenre.all
    @State private var apps: [StoreApp] = []
    @State private var loading = true
    @State private var issue: String?
    @State private var getting: StoreApp?

    private var platform: AppPlatform { store.settings.store.platform }
    @State private var region: String?
    private var country: String { region ?? store.settings.store.country }
    private var regions: [String] {
        var list = [store.settings.store.country.uppercased()]
        for code in store.settings.priceRegions.map({ $0.uppercased() }) where !list.contains(code) { list.append(code) }
        return list
    }

    var body: some View {
        List {
            Section {
                Picker("Chart", selection: $chart) {
                    ForEach(AppChart.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text(verbatim: "\(StoreRegions.flag(country.uppercased())) \(StoreRegions.name(country.uppercased())) · \(platform.title) · \(genre.title)")
            }
            if let issue, apps.isEmpty {
                Section { InlineIssue(message: issue) { Task { await load() } } }
            } else if loading && apps.isEmpty {
                Section { HStack(spacing: 10) { ProgressView(); Text("Loading chart…").foregroundStyle(.secondary) } }
            } else if apps.isEmpty {
                Section { Text("This chart is empty for now.").foregroundStyle(.secondary) }
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                Section {
                    NavigationLink { AppDetailView(app: app) } label: {
                        AppRow(app: app, subtitle: ["\(index + 1)", app.displayCategory].filter { !$0.isEmpty }.joined(separator: " · ")) {
                            RowCapsule(title: app.isFree ? "Get" : LocalizedStringKey(app.priceLabel)) { getting = app; UX.feedback() }
                                .accessibilityLabel(AppText.text("Get \(app.name)"))
                        }
                    }
                    .contextMenu {
                        Button(store.isFavorite(app) ? "Unfollow" : "Follow", systemImage: store.isFavorite(app) ? "bell.slash" : "bell") {
                            store.toggleFavorite(app); UX.feedback()
                        }
                    }
                }
            }
        }
        .toolPage().navigationTitle(chart.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Menu {
                    ForEach(regions, id: \.self) { code in
                        Button { region = code == store.settings.store.country.uppercased() ? nil : code } label: {
                            if code == country.uppercased() { Label(StoreRegions.flag(code) + " " + StoreRegions.name(code), systemImage: "checkmark") }
                            else { Text(StoreRegions.flag(code) + " " + StoreRegions.name(code)) }
                        }
                    }
                } label: {
                    Text(verbatim: StoreRegions.flag(country.uppercased())).font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(AppText.text("Chart region: \(StoreRegions.name(country.uppercased()))"))
                .accessibilityIdentifier("chart.region")
            }
            if platform != .macOS {
                ToolbarItem(placement: .compatibleTopBarTrailing) {
                    Menu {
                        Picker("Category", selection: $genre) {
                            ForEach(ChartGenre.allCases) { Text(verbatim: $0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: genre == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(AppText.text("Category: \(genre.title)"))
                }
            }
        }
        .compatibleNavigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .task(id: "\(chart.rawValue)-\(genre.rawValue)-\(country)-\(platform.rawValue)") { await load() }
    }

    private func load() async {
        loading = true; issue = nil; apps = []
        defer { loading = false }
        do {
            let next = try await ChartService.apps(chart, platform: platform, country: country, genre: genre)
            guard !Task.isCancelled else { return }
            apps = next
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription; apps = [] }
        }
    }
}
