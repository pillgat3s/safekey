import SwiftUI

/// First run, between the welcome and the master password: what SafeKey is
/// for, acknowledged with a tap. It sits before the vault is created and
/// before a backup can be restored, so there is no way around it.
struct ScopeNoticeView: View {
    var onAcknowledge: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(.tint)
                        .padding(.top, 64)
                        .accessibilityHidden(true)

                    Text(ScopeNotice.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                        .padding(.horizontal, 24)

                    Text(ScopeNotice.lead)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.horizontal, 32)

                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(ScopeNotice.points, id: \.title) { point in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: point.symbol)
                                    .font(.system(size: 29))
                                    .foregroundStyle(.tint)
                                    .frame(width: 40)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(point.title)
                                        .font(.headline)
                                    Text(point.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 36)
                    .padding(.horizontal, 30)
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }

            Button(action: onAcknowledge) {
                Text(ScopeNotice.acknowledge)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("scope.acknowledge")
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
    }
}
