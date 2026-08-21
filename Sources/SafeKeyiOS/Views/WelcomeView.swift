import SwiftUI

/// First-run welcome. Says what the app guarantees before asking for a
/// password, and is honest about the one that has no undo: forget the master
/// password and the vault is gone.
struct WelcomeView: View {
    var onContinue: () -> Void

    private struct Feature: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let features: [Feature] = [
        Feature(
            icon: "key.fill",
            title: "Never Lose a Seed Phrase",
            detail: "Every recovery phrase and private key in one place, ready the moment you need it."
        ),
        Feature(
            icon: "lock.fill",
            title: "Locked With Your Password",
            detail: "Your master password is the only key. Face ID opens the vault day to day."
        ),
        Feature(
            icon: "hand.raised.fill",
            title: "Nothing Leaves This Device Unless You Allow It",
            detail: "No account, no servers, no tracking. You can keep an encrypted backup in iCloud or Files — but only if you choose to."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    AppIconMark(size: 104)
                        .padding(.top, 56)

                    Text("Welcome to SafeKey")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 26)
                        .padding(.horizontal, 24)

                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(features) { feature in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: feature.icon)
                                    .font(.system(size: 29))
                                    .foregroundStyle(.tint)
                                    .frame(width: 40)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feature.title)
                                        .font(.headline)
                                    Text(feature.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 40)
                    .padding(.horizontal, 30)
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("welcome.continue")
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
    }
}
