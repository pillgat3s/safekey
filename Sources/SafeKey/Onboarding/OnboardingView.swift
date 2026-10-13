import SwiftUI
import AppKit
import SafeKeyCore

/// First-run flow: welcome card → what SafeKey is for → set master password
/// (or restore a backup) → vault created. Both ways forward from the welcome
/// pass through the notice, so a vault never exists without it having been
/// acknowledged.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = DebugSupport.startsAtScopeNotice ? .scope(then: .setPassword) : .welcome
    @State private var restoreError: String?

    enum Step: Equatable {
        case welcome
        case scope(then: Next)
        case setPassword
    }

    enum Next { case setPassword, restore }

    var body: some View {
        ZStack {
            VaultBackground()
            switch step {
            case .welcome:
                welcomeCard
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .scope(let next):
                ScopeNoticeCard {
                    switch next {
                    case .setPassword: step = .setPassword
                    case .restore: restoreFromBackup()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .setPassword:
                SetPasswordStepView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
    }

    private var welcomeCard: some View {
        GlassCard {
            VStack(spacing: 18) {
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 8)
                Text("SafeKey")
                    .font(.largeTitle.bold())
                Text("A local, fully encrypted vault for your wallet seed phrases and private keys. Nothing leaves this Mac unless you later turn on iCloud sync.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("Set Up Your Vault") {
                    step = .scope(then: .setPassword)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 6)

                Button("Restore from a Backup…") { step = .scope(then: .restore) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Restore Failed", isPresented: restoreErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "")
        }
    }

    private var restoreErrorBinding: Binding<Bool> {
        Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })
    }

    /// Restores an encrypted backup on a machine that has no vault yet — the
    /// primary recovery path after moving to a new Mac. The imported vault is
    /// opened with its own master password on the lock screen that follows.
    private func restoreFromBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose a SafeKey Backup"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                _ = try model.inspectBackup(data)      // reject non-containers before writing
                try await model.importVault(data)
            } catch {
                restoreError = "That file is not a valid SafeKey backup."
            }
        }
    }
}

/// Shared centered glass card used by onboarding and the unlock screen.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(36)
            .frame(minWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// Full-window backdrop behind unlock/onboarding cards.
struct VaultBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .underPageBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
