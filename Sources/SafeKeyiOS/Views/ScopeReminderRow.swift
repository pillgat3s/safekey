import SwiftUI

/// The short form of the first-run notice, shown at the top of the add-wallet
/// form until the person says they have seen it enough.
struct ScopeReminderRow: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(ScopeNotice.reminder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("entry.scopeReminder")
                Button("Don't Show Again", action: onDismiss)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("entry.scopeReminder.dismiss")
            }
        }
        .padding(.vertical, 2)
    }
}
