import SwiftUI
import UIKit

enum UX {
    static func motion(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)
    }
    static let tint = Color.accentColor
    static let buttonTint = Color.accentColor
    static let onAccent = Color(uiColor: .systemBackground)
    static let switchTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : (UIColor(named: "AccentColor") ?? .label)
    })
    static let iconCorner: CGFloat = 0.2237
    static func feedback() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? Color.white : UX.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background((configuration.role == .destructive ? Color.red : UX.buttonTint).opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.15), value: configuration.isPressed)
    }
}
typealias MonochromeButtonStyle = PrimaryButtonStyle

struct TintedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(UX.switchTint)
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.revealSuppressesPress) private var suppressesPress
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.isEnabled, enabled || suppressesPress)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(filled ? UX.onAccent : UX.tint)
            .padding(.horizontal, 16).frame(minWidth: 74, minHeight: 30)
            .background(filled ? AnyShapeStyle(UX.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(configuration.isPressed && !suppressesPress ? 0.6 : enabled || suppressesPress ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct RowCapsule: View {
    let title: LocalizedStringKey
    var filled = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold)).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(filled ? UX.onAccent : UX.tint)
            .padding(.horizontal, 16).frame(minWidth: 74, minHeight: 30)
            .background(filled ? AnyShapeStyle(UX.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .highPriorityGesture(TapGesture().onEnded { if enabled { action() } })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityAction { if enabled { action() } }
    }
}

struct ProgressRing: View {
    var progress: Double?
    var symbol = "pause.fill"
    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(UX.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            if progress == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(UX.tint)
            }
        }
        .frame(width: 30, height: 30)
        .padding(7)
        .contentShape(Circle())
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image("BrandMark").resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous)).accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(CapsuleButtonStyle()).padding(.top, 8)
            }
        }.padding(.vertical, 28).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
}

struct InlineIssue: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let retry { Button("Retry", action: retry).buttonStyle(CapsuleButtonStyle()) }
            }
        }.padding(.vertical, 6)
    }
}

struct SearchInput: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var capsule = false
    var submit: (() -> Void)? = nil
    var clear: (() -> Void)? = nil
    @FocusState private var focused: Bool
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($focused)
                .onSubmit { focused = false; if !trimmed.isEmpty { submit?() } }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = ""; clear?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 32, height: 32) }
                    .buttonStyle(.borderless).accessibilityLabel("Clear text")
            }
            if submit != nil && !capsule {
                Button { focused = false; submit?() } label: { Text("Search").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.borderless)
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel("Search apps").accessibilityIdentifier("search.submit")
            }
        }
        .padding(.leading, capsule ? 14 : 10).padding(.trailing, capsule ? 6 : 8)
        .frame(minHeight: capsule ? 44 : 40)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: capsule ? 22 : 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

struct RefreshButton: View {
    let busy: Bool
    let action: () -> Void
    @State private var showsSpinner = false
    var body: some View {
        ZStack(alignment: .trailing) {
            Button("Refresh") { if !busy { action() } }
                .font(.body).textCase(nil)
                .opacity(showsSpinner ? 0 : 1)
            if showsSpinner { ProgressView().controlSize(.small).transition(.opacity) }
        }
        .revealAfterDelay(busy, into: $showsSpinner)
        .accessibilityValue(busy ? "Refreshing" : "")
    }
}

struct RootTabBar: ViewModifier {
    let title: LocalizedStringKey
    let headerScrolledAway: Bool
    func body(content: Content) -> some View {
        content
            .compatibleVerticalContentMargin(.top, 0)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.headline)
                        .opacity(headerScrolledAway ? 1 : 0)
                        .animation(.easeInOut(duration: 0.18), value: headerScrolledAway)
                        .accessibilityHidden(!headerScrolledAway)
                }
            }
    }
}
extension View {
    func revealAfterDelay(_ active: Bool, into shown: Binding<Bool>, delay: Duration = .milliseconds(300)) -> some View {
        task(id: active) {
            guard active else {
                if shown.wrappedValue { withAnimation(.easeOut(duration: 0.15)) { shown.wrappedValue = false } }
                return
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { shown.wrappedValue = true }
        }
    }
    func rootTabBar(_ title: LocalizedStringKey, headerScrolledAway: Bool) -> some View {
        modifier(RootTabBar(title: title, headerScrolledAway: headerScrolledAway))
    }
    func onScrolledUnderBar(_ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .global).maxY < 104
        } action: { action($0) }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
}

struct TaskStatusPill: View {
    let status: DownloadStatus
    private var color: Color {
        switch status {
        case .failed: return .red
        case .completed: return .green
        case .paused: return .secondary
        default: return UX.tint
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol).imageScale(.small)
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

struct TagBadge: View {
    let text: LocalizedStringKey
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(nil)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
    }
}

struct AppSkeleton: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemFill)).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 150, height: 13)
                RoundedRectangle(cornerRadius: 4).fill(Color(.quaternarySystemFill)).frame(width: 100, height: 10)
            }
            Spacer()
            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 74, height: 30)
        }.padding(.vertical, 6).accessibilityHidden(true)
    }
}

struct InfoStripItem: View {
    let caption: LocalizedStringKey
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    var body: some View {
        VStack(spacing: 4) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.title3.weight(.semibold))
                } else {
                    Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.secondary)
            .frame(height: 26)
            Text(detail ?? (symbol == nil ? " " : value)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct VerificationCodeField: View {
    @Binding var code: String
    var length = 6
    var disabled = false
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .disabled(disabled)
                .foregroundStyle(.clear).tint(.clear)
                .frame(width: 1, height: 1).opacity(0.02)
                .accessibilityIdentifier("apple.verification.code")
                .compatibleOnChange(of: code) { value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(length))
                    if digits != value { code = digits; return }
                    if digits.count == length { onComplete(digits) }
                }
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let characters = Array(code)
                    let current = index == characters.count && focused
                    Text(index < characters.count ? String(characters[index]) : "")
                        .font(.title.monospacedDigit().weight(.semibold))
                        .frame(width: 44, height: 56)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(current ? UX.tint : Color(.separator), lineWidth: current ? 2 : 0.5))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Verification code, \(code.count) of 6 digits entered")
        }
        .onAppear { if !disabled { focused = true } }
        .compatibleOnChange(of: disabled) { value in if !value { focused = true } }
    }
}

struct ToolPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
            .compatibleListSectionSpacing(20)
            .compatibleVerticalContentMargin(.bottom, 20)
    }
}
extension View { func toolPage() -> some View { modifier(ToolPageStyle()) } }

struct MarqueeText: View {
    let text: String
    var font: Font = .subheadline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    var body: some View {
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .offset(x: offset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if overflow > 0 {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
            .task(id: overflow) {
                offset = 0
                guard overflow > 1, !reduceMotion else { return }
                do {
                    try await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeInOut(duration: max(0.8, Double(overflow) / 35))) { offset = -overflow - 14 }
                    try await Task.sleep(for: .milliseconds(Int(max(0.8, Double(overflow) / 35) * 1000) + 1200))
                    withAnimation(.easeInOut(duration: 0.45)) { offset = 0 }
                } catch { offset = 0 }
            }
    }
}

extension AnyTransition {
    static var statusSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92))
                .animation(.easeOut(duration: 0.18).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

extension Animation {
    static var compatibleSnappy: Animation {
        if #available(iOS 17, *) { return .snappy }
        return compatibleSnappy(duration: 0.5)
    }
    static func compatibleSnappy(duration: Double) -> Animation {
        if #available(iOS 17, *) { return .snappy(duration: duration) }
        return .spring(response: duration, dampingFraction: 0.85)
    }
}

extension View {
    @ViewBuilder func compatibleSymbolReplacement() -> some View {
        if #available(iOS 17, *) { contentTransition(.symbolEffect(.replace)) }
        else { contentTransition(.opacity) }
    }
    @ViewBuilder func compatibleSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17, *) { sensoryFeedback(.selection, trigger: trigger) }
        else { onChange(of: trigger) { _ in UISelectionFeedbackGenerator().selectionChanged() } }
    }
    @ViewBuilder func compatiblePresentationCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) { presentationCornerRadius(radius) }
        else { self }
    }
    @ViewBuilder func compatibleListSectionSpacing(_ spacing: CGFloat) -> some View {
        if #available(iOS 17, *) { listSectionSpacing(spacing) }
        else { self }
    }
    @ViewBuilder func compatibleVerticalContentMargin(_ edge: Edge.Set, _ length: CGFloat) -> some View {
        if #available(iOS 17, *) { contentMargins(edge, length, for: .scrollContent) }
        else if edge == .bottom {
            safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: length).allowsHitTesting(false) }
        } else { self }
    }
    @ViewBuilder func compatibleScrollTargetLayout() -> some View {
        if #available(iOS 17, *) { scrollTargetLayout() }
        else { self }
    }
    @ViewBuilder func compatibleViewAlignedScrolling() -> some View {
        if #available(iOS 17, *) { scrollTargetBehavior(.viewAligned) }
        else { self }
    }
}

struct CompatibleCardShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        if #available(iOS 17, *) {
            return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous).path(in: rect)
        }
        let limit = max(0, min(rect.width, rect.height) / 2)
        let t = min(max(0, top), limit), b = min(max(0, bottom), limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - t, y: rect.minY + t), radius: t,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        path.addArc(center: CGPoint(x: rect.maxX - b, y: rect.maxY - b), radius: b,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + b, y: rect.maxY - b), radius: b,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        path.addArc(center: CGPoint(x: rect.minX + t, y: rect.minY + t), radius: t,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

extension ToolbarItemPlacement {
    static var compatibleTopBarLeading: Self {
        if #available(iOS 17, *) { return .topBarLeading }
        return .navigationBarLeading
    }

    static var compatibleTopBarTrailing: Self {
        if #available(iOS 17, *) { return .topBarTrailing }
        return .navigationBarTrailing
    }
}

extension View {
    @ViewBuilder func compatibleOnChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17, *) { onChange(of: value) { _, newValue in action(newValue) } }
        else { onChange(of: value, perform: action) }
    }

    @ViewBuilder func compatibleNavigationDestination<Item: Hashable, Destination: View>(
        item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            navigationDestination(isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )) {
                if let value = item.wrappedValue { destination(value) }
            }
        }
    }

    @ViewBuilder func compatibleInteractionShape<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 17, *) { contentShape([.interaction, .accessibility], shape) }
        else { contentShape(.interaction, shape) }
    }

    @ViewBuilder func compatibleScrollBounce() -> some View {
        if #available(iOS 16.4, *) { scrollBounceBehavior(.basedOnSize) }
        else { self }
    }

    @ViewBuilder func compatibleBounce(trigger: some Equatable) -> some View {
        if #available(iOS 17, *) { symbolEffect(.bounce, value: trigger) }
        else { self }
    }

    @ViewBuilder func compatibleHorizontalScrollMargins(_ margin: CGFloat) -> some View {
        if #available(iOS 17, *) { contentMargins(.horizontal, margin, for: .scrollContent) }
        else { self }
    }

    @ViewBuilder func legacyHorizontalPadding(_ margin: CGFloat) -> some View {
        if #available(iOS 17, *) { self }
        else { padding(.horizontal, margin) }
    }
}
