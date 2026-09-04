import SwiftUI
import AppKit
import LocalAuthentication
import SafeKeyCore

/// The lock screen, modelled on Apple's Passwords app: the app icon with a
/// Touch ID badge, a one-line explanation, and a single password field —
/// centred on the window rather than presented as a panel.
///
/// Touch ID is **armed** whenever this screen is showing and the app is active,
/// because macOS keeps the sensor live only while an `evaluatePolicy` call is
/// pending. There is no passive mode: with nothing pending, resting a finger on
/// the sensor does nothing at all, which is precisely the trap this screen fell
/// into when the automatic prompt was removed and a small badge became the only
/// way in. The `NSApp.isActive` gate is what keeps a background inactivity
/// re-lock from throwing a dialog over whatever the user is doing instead.
struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    /// The context the embedded control is bound to and the policy is evaluated
    /// against. It must exist *before* the control mounts and before the
    /// evaluation starts, so it is held here rather than created at use.
    /// Single-use: replaced after every attempt, which remounts the control.
    @State private var authContext = LAContext()
    /// True while an evaluation is pending. macOS keeps the Touch ID sensor
    /// live only while one is in flight — there is no passive arming — so this
    /// is what makes resting a finger on the sensor do anything at all.
    @State private var isArmed = false
    /// Set when the user explicitly cancels, so we do not immediately re-prompt
    /// them in a loop. Cleared when they leave and return, or on a manual retry.
    @State private var suppressAutoPrompt = false
    @FocusState private var passwordFocused: Bool

    private var appName: String { DisguiseManager.shared.effectiveName }

    private var biometricsAvailable: Bool { model.canUnlockWithBiometrics }

    var body: some View {
        ZStack {
            // Behind-window vibrancy, so the lock screen picks up the desktop
            // the way Apple's does.
            VisualEffectBackground(material: .underWindowBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                icon
                    .padding(.bottom, 20)

                Text("\(appName) Is Locked")
                    .font(.system(size: 22, weight: .bold))

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .padding(.top, 6)

                passwordField
                    .padding(.top, 22)

                status
                    .padding(.top, 14)
            }
            .padding(40)
            // Centred, nudged just below the middle as Apple's is.
            .offset(y: 20)
        }
        .chromelessWindow(compactSize: NSSize(width: 640, height: 560), translucent: true)
        .onAppear {
            passwordFocused = true
            // Recompute rather than trust the cached flag: it has been observed
            // going stale, leaving the badge hidden when enrolment was fine.
            model.refreshBiometricAvailability()
            BiometricDiagnosticLog.record(
                "lock screen shown — badge \(model.canUnlockWithBiometrics ? "VISIBLE" : "HIDDEN")"
            )
            armTouchID()
        }
        // Arm on return to the app. The `NSApp.isActive` gate inside armTouchID
        // is what stops a background auto-lock throwing up a prompt: the timer
        // may re-lock at any moment, but nothing is presented until the user
        // actually comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            armTouchID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            // Deliberately does NOT invalidate a pending authentication. The
            // Touch ID prompt is its own window, so raising it makes this app
            // resign active — tearing the context down here cancelled the very
            // prompt we had just armed, one millisecond after arming it. The
            // system owns that panel's lifetime; leave it alone.
            //
            // Leaving and returning is a fresh intent, so a previous cancel
            // should not keep suppressing the prompt.
            suppressAutoPrompt = false
        }
    }

    // MARK: - Pieces

    /// App icon with the Touch ID badge.
    ///
    /// The badge lives inside a ZStack sized to contain it, rather than being
    /// pushed past the icon's edge with `.offset`. SwiftUI draws content that
    /// overflows a parent's bounds but will not hit-test it, so an offset badge
    /// looks perfectly normal and silently ignores every click.
    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                // Apple's lock screen sits at roughly 1 : 2.4 icon-to-field width.
                .frame(width: 96, height: 96)
                .padding(.trailing, 10)
                .padding(.bottom, 8)

            embeddedAuthentication
        }
        .fixedSize()
    }

    /// Apple's authentication control, given its own space below the password
    /// field at its natural size. It renders only while an evaluation is
    /// pending, so it is invisible until Touch ID is armed. Rebuilt with each
    /// new context, since a context that has already evaluated draws nothing.
    @ViewBuilder
    private var embeddedAuthentication: some View {
        if biometricsAvailable {
            EmbeddedAuthenticationView(context: authContext, controlSize: .small)
                .id(ObjectIdentifier(authContext))
                .frame(width: 46, height: 46)
                // With the badge gone this is the only Touch ID affordance, so
                // it doubles as the manual retry after a cancel.
                .contentShape(Rectangle())
                .onTapGesture { armTouchID(manual: true) }
                .help("Unlock with Touch ID")
                .accessibilityLabel("Unlock with Touch ID")
        }
    }

    private var subtitle: String {
        if model.requiresDeviceKey {
            return biometricsAvailable
                ? "Insert your security key, then use Touch ID or enter your master password to unlock."
                : "Insert your security key and enter your master password to unlock."
        }
        return biometricsAvailable
            ? "Touch ID or enter your master password to unlock."
            : "Enter your master password to unlock."
    }

    private var passwordField: some View {
        SecureField("", text: $password, prompt: Text("Enter password"))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .multilineTextAlignment(.center)
            .focused($passwordFocused)
            .onSubmit(submit)
            .disabled(isUnlocking)
            // ≈2.4× the icon width, matching Apple's proportions.
            .frame(width: 254, height: 38)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        passwordFocused ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: passwordFocused ? 3 : 1
                    )
            )
            .overlay(alignment: .trailing) {
                if isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 10)
                }
            }
            .animation(.easeOut(duration: 0.12), value: passwordFocused)
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            if model.requiresDeviceKey {
                Label(
                    model.volumeWatcher.deviceKeyPresent
                        ? "Security key connected"
                        : "Insert your security key…",
                    systemImage: model.volumeWatcher.deviceKeyPresent ? "checkmark.circle.fill" : "mediastick"
                )
                .font(.system(size: 12))
                .foregroundStyle(model.volumeWatcher.deviceKeyPresent ? .green : .secondary)
                .animation(.easeOut(duration: 0.2), value: model.volumeWatcher.deviceKeyPresent)
            }

            if model.tamperDetected {
                // Computed from the file alone — no password involved, so this
                // reveals nothing to anyone watching.
                Label(
                    "This vault file changed since you last unlocked it. Self-destruct is disabled until you open it successfully.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            }

            if let remaining = model.remainingAttempts {
                Label(
                    remaining == 1
                        ? "Last attempt — the vault will be erased on the next wrong password."
                        : "Self-destruct armed: \(remaining) attempts remaining.",
                    systemImage: "flame.fill"
                )
                .font(.system(size: 12))
                .foregroundStyle(remaining <= 2 ? .red : .orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            }
        }
    }

    // MARK: - Actions

    /// Return on an empty field asks for Touch ID, matching the "Touch ID or
    /// enter the password" affordance.
    private func submit() {
        if password.isEmpty, biometricsAvailable {
            armTouchID()
        } else {
            unlock()
        }
    }

    private func unlock() {
        guard !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        errorMessage = nil
        let attempt = password
        Task {
            do {
                try await model.unlock(password: attempt)
                password = ""
            } catch VaultError.wrongPassword {
                errorMessage = "Wrong password."
                password = ""
                isUnlocking = false
                passwordFocused = true
            } catch VaultError.deviceKeyRequired {
                errorMessage = "Insert your security key first."
                isUnlocking = false
            } catch VaultError.tampered {
                errorMessage = "Your password was accepted, but the vault data has been damaged or modified. Restore a backup you trust — nothing was counted against self-destruct."
                password = ""
                isUnlocking = false
            } catch VaultError.corruptVault {
                errorMessage = "This vault file is damaged and cannot be read."
                isUnlocking = false
            } catch VaultError.vaultNotFound {
                // Usually self-destruct, which has already switched the app to
                // its setup screen; if the file simply vanished, say so rather
                // than spin for ever.
                password = ""
                isUnlocking = false
                if case .locked = model.state { errorMessage = "The vault file is missing." }
            } catch {
                errorMessage = "Could not open the vault: \(error.localizedDescription)"
                isUnlocking = false
            }
        }
    }

    /// Starts an authentication and leaves it pending, which is the only way to
    /// make the Touch ID sensor live. Called when the lock screen appears, when
    /// the app is reactivated, and when the badge is clicked.
    ///
    /// `manual` marks a deliberate badge press: it clears a previous cancel so
    /// the user can always retry, where the automatic path stays quiet.
    private func armTouchID(manual: Bool = false) {
        if manual { suppressAutoPrompt = false }

        guard biometricsAvailable else { return }
        guard !isUnlocking, !isArmed else {
            BiometricDiagnosticLog.record("arm skipped — already authenticating")
            return
        }
        guard !suppressAutoPrompt || manual else {
            BiometricDiagnosticLog.record("arm skipped — suppressed after cancel")
            return
        }
        // Never prompt from the background: an inactivity re-lock must not throw
        // a dialog over whatever the user is actually doing.
        guard NSApp.isActive else {
            BiometricDiagnosticLog.record("arm skipped — app not active")
            return
        }

        BiometricDiagnosticLog.record("arming Touch ID (manual: \(manual))")
        errorMessage = nil
        // macOS owns the biometric prompt — an app may never draw its own, or
        // any app could fake one. What we can influence is where it appears:
        // with the app active and its window key, the system attaches the
        // prompt to that window instead of floating it loose on the desktop.
        NSApp.activate()
        NSApp.windows.first(where: \.isVisible)?.makeKeyAndOrderFront(nil)
        let context = authContext
        isArmed = true

        Task {
            defer {
                isArmed = false
                // A context cannot be reused once it has evaluated; replacing it
                // remounts the embedded control ready for the next attempt.
                authContext = LAContext()
            }
            do {
                try await model.unlockWithBiometrics(
                    deviceKey: model.volumeWatcher.currentDeviceKey(),
                    context: context
                )
                BiometricDiagnosticLog.record("unlock SUCCEEDED")
            } catch BiometricError.cancelled {
                // Dismissed on purpose — do not immediately re-arm, or the user
                // is trapped in a prompt loop. The badge is the way back in.
                BiometricDiagnosticLog.record("cancelled by user — auto-prompt suppressed")
                suppressAutoPrompt = true
                passwordFocused = true
            } catch BiometricError.interrupted {
                // Torn down by deactivation or invalidate(), not by the user, so
                // leave the automatic prompt armed for their return.
                BiometricDiagnosticLog.record("interrupted — will re-arm on return")
            } catch BiometricError.notEnrolled {
                errorMessage = "Touch ID needs setting up again — the stored key is gone, which happens when the app is reinstalled. Unlock with your password, then re-enable it in Settings → Security."
                isUnlocking = false
                passwordFocused = true
            } catch is BiometricError {
                errorMessage = "Touch ID unavailable — use your password."
                isUnlocking = false
            } catch VaultError.deviceKeyRequired {
                errorMessage = "Insert your security key, then try again."
                isUnlocking = false
            } catch {
                // Surface the underlying error rather than a generic message.
                // A vague failure string is what made this impossible to
                // diagnose: every distinct cause looked identical on screen.
                errorMessage = "Touch ID failed: \(BiometricDiagnosticLog.describe(error))"
                BiometricDiagnosticLog.record("unlock failed", error: error)
                isUnlocking = false
            }
        }
    }
}
