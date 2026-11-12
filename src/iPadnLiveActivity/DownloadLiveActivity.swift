import ActivityKit
import SwiftUI
import WidgetKit

private extension DownloadActivityAttributes.ContentState {
    var title: String {
        switch phase {
        case 0: return String(localized: "Downloading")
        case 1: return String(localized: "Preparing the package")
        case 2: return String(localized: "Download complete")
        default: return String(localized: "Waiting")
        }
    }
    var fraction: Double {
        guard expected > 0 else { return phase == 2 ? 1 : 0 }
        return min(1, max(0, Double(written) / Double(expected)))
    }
    var interval: ClosedRange<Date>? {
        guard phase == 0, let end = estimatedEnd, end > updated, fraction < 1 else { return nil }
        let start = end.addingTimeInterval(-end.timeIntervalSince(updated) / (1 - fraction))
        return start...end
    }
    var bytes: String {
        guard expected > 0 else { return "" }
        let style = ByteCountFormatter()
        style.countStyle = .file
        return style.string(fromByteCount: written) + " / " + style.string(fromByteCount: expected)
    }
    var others: String? { count > 1 ? String(localized: "\(count - 1) more jobs") : nil }
    var tint: Color { phase == 2 ? .green : .accentColor }
}

private struct DownloadBar: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        Group {
            if let interval = state.interval {
                ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: state.fraction)
            }
        }
        .tint(state.tint)
    }
}

private struct DownloadRing: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        Group {
            if state.phase == 2 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let interval = state.interval {
                ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
            } else {
                ProgressView(value: state.fraction).progressViewStyle(.circular)
            }
        }
        .tint(state.tint)
        .frame(width: 20, height: 20)
    }
}

private struct DownloadTrailing: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        if let interval = state.interval, interval.upperBound > .now {
            Text(timerInterval: Date.now...interval.upperBound, countsDown: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
        } else if state.phase == 0 {
            Text(state.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
        } else {
            Text(state.phase == 2 ? String(localized: "Done") : state.phase == 1 ? String(localized: "Preparing") : String(localized: "Waiting"))
        }
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            let state = context.state
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AppMarkView(size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(state.name).font(.headline).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    DownloadTrailing(state: state).font(.subheadline.weight(.semibold)).frame(maxWidth: 80, alignment: .trailing)
                }
                if state.phase != 2 { DownloadBar(state: state) }
                HStack {
                    Text(state.bytes)
                    Spacer()
                    if let others = state.others { Text(others) }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(16)
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AppMarkView(size: 34).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DownloadTrailing(state: state).font(.headline).foregroundStyle(state.tint)
                        .frame(maxWidth: 76, alignment: .trailing).padding(.trailing, 4).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.title).font(.caption).foregroundStyle(.secondary)
                        Text(state.name).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if state.phase != 2 { DownloadBar(state: state) }
                        HStack {
                            Text(state.bytes)
                            Spacer()
                            if let others = state.others { Text(others) }
                        }
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                AppMarkView(size: 22)
            } compactTrailing: {
                DownloadRing(state: state)
            } minimal: {
                DownloadRing(state: state)
            }
            .keylineTint(state.tint)
        }
    }
}
