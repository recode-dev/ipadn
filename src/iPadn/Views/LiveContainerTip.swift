import SwiftUI

/// Shown on the Downloads page when iPadn runs inside LiveContainer: its
/// "Fix File Picker" app setting makes importing, exporting and the system
/// install prompt work (thanks to issue #44).
struct LiveContainerTip: View {
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Using iPadn in LiveContainer").font(.subheadline.weight(.semibold))
                // The option keeps LiveContainer's own name in each language.
                Text("In LiveContainer, long-press iPadn and turn on “\(AppText.text("Fix File Picker"))” in its settings. Then importing and exporting packages and diagnostics works, and one-tap install can show the system install prompt.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("OK", action: dismiss).buttonStyle(CapsuleButtonStyle())
                    .accessibilityIdentifier("downloads.livecontainer-tip.dismiss")
            }
        }
        .padding(.vertical, 6)
    }
}
