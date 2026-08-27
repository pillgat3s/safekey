import SwiftUI
import SafeKeyCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    private var isLocked: Bool {
        if case .locked = model.state { return true }
        return false
    }

    private var blocksCapture: Bool {
        if let session = model.session {
            return session.settings.effectiveBlockScreenCapture
        }
        return !isLocked
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(minWidth: 560, minHeight: 480)
            case .noVault:
                // Setup and unlock are compact windows; only the three-pane
                // vault needs the wide minimum, and imposing it here would stop
                // the window shrinking for them.
                OnboardingView()
                    .frame(minWidth: 560, minHeight: 520)
            case .locked:
                UnlockView()
                    .frame(minWidth: 560, minHeight: 480)
            case .unlocked(let session):
                MainSplitView(session: session)
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
        // The lock screen shows no secrets, and excluding a window from screen
        // capture appears to stop the system attaching the biometric prompt to
        // it. Past the lock screen the user's own setting decides — on unless
        // they switched it off, and re-applied live when they do.
        .protectedWindow(blocksScreenCapture: blocksCapture)
        .task {
            if case .loading = model.state {
                await model.bootstrap()
            }
        }
    }
}
