import SwiftUI

/// First run, between the welcome and whatever comes next — the master
/// password, or restoring a backup: what SafeKey is for, acknowledged with a
/// click. Nothing creates or restores a vault until it has been.
struct ScopeNoticeCard: View {
    var onAcknowledge: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 16) {
                Image(systemName: "key.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(ScopeNotice.title)
                    .font(.title2.bold())
                Text(ScopeNotice.lead)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ScopeNotice.points, id: \.title) { point in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: point.symbol)
                                .font(.system(size: 20))
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.title).font(.headline)
                                Text(point.detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                .padding(.top, 6)

                Button(ScopeNotice.acknowledge, action: onAcknowledge)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("scope.acknowledge")
                    .padding(.top, 8)
            }
        }
    }
}
