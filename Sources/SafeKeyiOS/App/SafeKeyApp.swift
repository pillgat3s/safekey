import SwiftUI
import SafeKeyCore

/// Refuses third-party keyboard extensions for the whole app, the way Apple's
/// own Passwords app does.
///
/// A custom keyboard is an app that sees every keystroke, and a vault is the
/// one place a typed seed phrase must not pass through someone else's code.
/// iOS only enforces the system keyboard by itself for secure fields, and a
/// multi-line seed editor cannot be one — so the app declines the extension
/// point outright and every field gets Apple's keyboard.
final class KeyboardPolicyDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier identifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        identifier != .keyboard
    }
}

@main
struct SafeKeyApp: App {
    @UIApplicationDelegateAdaptor(KeyboardPolicyDelegate.self) private var keyboardPolicy
    @State private var model = AppModel.forCurrentLaunch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(model)
                    // Writing Tools would hand any selected text — a seed
                    // phrase in the editor, say — to Apple Intelligence.
                    // Off for every field in the app; nothing typed into a
                    // vault is prose that needs rewriting.
                    .writingToolsBehavior(.disabled)
                    .task {
                        if case .loading = model.state { await model.bootstrap() }
                    }

                // Locking on `.background` is not enough on its own: iOS takes
                // the app-switcher snapshot around the transition, and the
                // switcher is where a shoulder-surfer looks. Covering from
                // `.inactive` means the snapshot can only ever contain this.
                //
                // A prompt of our own is the exception. The Face ID panel makes
                // the scene inactive as well, and stays up for a couple of
                // seconds after a match; covering the opened vault for that
                // long read as the app hanging on every unlock. The cover sits
                // out from the prompt until the scene is active again.
                if scenePhase != .active, !model.isAuthenticating {
                    PrivacyCover()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scenePhase)
            .onChange(of: scenePhase) { _, phase in
                // Leaving the foreground on a phone is the equivalent of
                // walking away from a desk.
                if phase == .background { model.lock() }
                if phase == .active { model.noteSceneActive() }
                UnlockTrace.mark("app-phase-\(phase)")
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .noVault:
            OnboardingView()
        case .locked:
            LockScreenView()
        case .unlocked(let session):
            // iPad gets the sidebar layout the Passwords app uses there; a
            // compact width — every iPhone, and iPad slide-over — gets the
            // tile home screen. Driven by size class rather than device so
            // multitasking picks the right one on its own.
            // Either one picks up where the last session was: the model kept
            // the route, as identifiers, across the lock.
            let resume = model.resume.validated(in: session)
            if horizontalSizeClass == .regular {
                VaultSplitView(session: session, resume: resume)
            } else {
                VaultHomeView(session: session, resume: resume.homePath)
            }
        }
    }
}
