import Foundation

struct PricePoint: Codable, Hashable {
    var date: Date
    var price: Double
}

enum WatchChange: Codable, Hashable {
    case newVersion(String)
    case priceDrop(from: Double, to: Double)
    case free(from: Double)
    case priceRise(from: Double, to: Double)
    case delisted
    case relisted

    var rank: Int {
        switch self {
        case .free: return 5
        case .priceDrop: return 4
        case .delisted: return 3
        case .newVersion: return 2
        case .relisted: return 1
        case .priceRise: return 0
        }
    }
}

struct WatchRecord: Codable, Equatable {
    var id: String
    var country: String
    var version = ""
    var price: Double?
    var currency = ""
    var delisted = false
    var history: [PricePoint] = []
    var started: Date
    var checked: Date
    var change: WatchChange?
    var changed: Date?
    var target: Double?

    var key: String { Self.key(id: id, country: country) }
    static func key(id: String, country: String) -> String { id + "|" + country.uppercased() }
    var listed: Bool { !version.isEmpty || price != nil }
    func recentChange(now: Date = Date()) -> WatchChange? {
        guard let change, let changed, now.timeIntervalSince(changed) < 7 * 86400 else { return nil }
        return change
    }
}

enum WatchService {
    static let historyLimit = 400

    static func update(_ record: WatchRecord?, id: String, country: String, listing: StoreApp?,
                       now: Date = Date()) -> (record: WatchRecord, changes: [WatchChange]) {
        var next = record ?? WatchRecord(id: id, country: country.uppercased(), started: now, checked: now)
        next.checked = now
        var changes: [WatchChange] = []
        if let listing {
            if record?.delisted == true { changes.append(.relisted) }
            next.delisted = false
            if let old = record?.version, VersionOrder.isNewer(listing.version, than: old) {
                changes.append(.newVersion(listing.version))
            }
            if !listing.version.isEmpty { next.version = listing.version }
            if let price = listing.priceValue, price >= 0 {
                let currency = listing.currency ?? next.currency
                if !next.currency.isEmpty, currency != next.currency {
                    next.history = []; next.price = nil; next.target = nil
                }
                if let old = next.price, !same(old, price) {
                    changes.append(price == 0 ? .free(from: old) : price < old ? .priceDrop(from: old, to: price)
                                   : .priceRise(from: old, to: price))
                }
                if next.history.last.map({ !same($0.price, price) }) ?? true {
                    next.history.append(PricePoint(date: now, price: price))
                    next.history = Array(next.history.suffix(historyLimit))
                }
                next.price = price
                next.currency = currency
            }
        } else if record?.listed == true, record?.delisted == false {
            next.delisted = true
            changes.append(.delisted)
        }
        if let notable = changes.max(by: { $0.rank < $1.rank }) {
            next.change = notable; next.changed = now
        }
        return (next, changes)
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_1 }

    static func notifies(_ change: WatchChange, target: Double?) -> Bool {
        guard let target, case .priceDrop(_, let price) = change else { return true }
        return price <= target + 0.000_1
    }

    static func format(_ price: Double, currency: String, locale: Locale = AppText.formattingLocale) -> String {
        if price == 0 { return AppText.text("Free") }
        let whole = price.rounded() == price
        return formatters.withLock { cache in
            let key = locale.identifier + "|" + currency + (whole ? "|0" : "|2")
            let formatter = cache[key] ?? {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.locale = locale
                if !currency.isEmpty { formatter.currencyCode = currency }
                formatter.minimumFractionDigits = whole ? 0 : 2
                formatter.maximumFractionDigits = 2
                return formatter
            }()
            cache[key] = formatter
            return formatter.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
        }
    }
    private static let formatters = NSLockedValue([String: NumberFormatter]())

    static func message(_ change: WatchChange, currency: String, locale: Locale = AppText.formattingLocale) -> String? {
        switch change {
        case .newVersion(let version): return AppText.text("Version \(version) is available")
        case .priceDrop(let from, let to): return AppText.text("Price drop: \(format(from, currency: currency, locale: locale)) → \(format(to, currency: currency, locale: locale))")
        case .free(let from): return AppText.text("Now free (was \(format(from, currency: currency, locale: locale)))")
        case .delisted: return AppText.text("Removed from the App Store. Accounts that acquired it can still download it; back it up soon.")
        case .relisted: return AppText.text("Relisted")
        case .priceRise: return nil
        }
    }
}

enum PurchaseExport {
    static func csv(_ apps: [OwnedApp], listed: [String: Bool], downloaded: Set<String>, locale: Locale = AppText.locale) -> String {
        var rows = [[AppText.text("Name", in: locale), AppText.text("App ID", in: locale), AppText.text("Bundle ID", in: locale),
                     AppText.text("Version", in: locale), AppText.text("Purchase date", in: locale), AppText.text("Store status", in: locale),
                     AppText.text("Downloaded", in: locale)]]
        let date = Date.FormatStyle().year().month(.twoDigits).day(.twoDigits)
        for app in apps {
            let status = listed[app.id].map { $0 ? AppText.text("On sale", in: locale) : AppText.text("Removed", in: locale) } ?? AppText.text("Not checked", in: locale)
            rows.append([app.name, app.id, app.bundleID, app.version, app.purchaseDate.map { $0.formatted(date) } ?? "",
                         status, downloaded.contains(app.id) ? AppText.text("Yes", in: locale) : AppText.text("No", in: locale)])
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
