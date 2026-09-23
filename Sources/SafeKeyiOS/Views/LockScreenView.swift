import SwiftUI
import LocalAuthentication
import SafeKeyCore

/// The lock screen, in the shape iOS gives a locked credential vault: the app
/// icon under a lock, a title, one Unlock button.
///
/// Face ID is nothing to press for. It starts the moment the app is active
/// with this on screen, and again each time the app comes back, so the usual
/// open is a glance. The master password is the fallback behind it, shown on
/// request or when biometrics decline.
struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var showingPasswordField = false
    /// One automatic prompt per stay in the foreground. The sensor only
    /// answers while an evaluation is pending, so each return arms it once;
    /// a prompt the user dismissed is not raised again until they leave and
    /// come back. Reset on `.background` only: the Face ID sheet itself, the
    /// notification shade and the app switcher all pass through `.inactive`,
    /// and re-arming there would prompt in a loop.
    @State private var armed = false
    @FocusState private var passwordFocused: Bool

    private var biometricsFirst: Bool { model.canUnlockWithBiometrics && !showingPasswordField }

    var body: some View {
        ZStack {
            // The grey a locked credential vault dims to, rather than black.
            Color(.secondarySystemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                LockedAppIcon(size: 112)

                Text("SafeKey Is Locked")
                    .font(.title.bold())
                    .padding(.top, 26)

                notices

                if biometricsFirst {
                    Button(action: unlockWithBiometrics) {
                        Text("Unlock")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(isUnlocking)
                    .padding(.top, 30)
                    .accessibilityIdentifier("lock.biometrics")

                    Button("Use Master Password") {
                        showingPasswordField = true
                        passwordFocused = true
                    }
                    .font(.subheadline)
                    .padding(.top, 18)
                } else {
                    passwordEntry
                }

                Spacer()
                Spacer()
            }
            // A single column rather than controls stretched across the full
            // width: without this a landscape iPhone — and any iPad — renders
            // a password field the width of the screen.
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        // Only an active app may raise the prompt. While inactive or in the
        // background the system refuses it, which used to arrive as "Face ID
        // unlock failed" before anyone had looked at the phone: the vault
        // locks on the way *out*, so this screen used to appear — and ask —
        // in the background.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                UnlockTrace.begin("resume")
                UnlockTrace.mark("scene-active")
                armIfNeeded()
            case .inactive:
                UnlockTrace.mark("scene-inactive")
            case .background:
                armed = false
            @unknown default:
                break
            }
        }
        .onAppear { UnlockTrace.mark("lock-appeared") }
    }

    @ViewBuilder
    private var notices: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 10)
        }

        if model.tamperDetected {
            Label("This vault changed since it was last opened.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 10)
        }

        if let remaining = model.remainingAttempts {
            Label(
                remaining == 1
                    ? "Last attempt — the vault will be erased on the next wrong password."
                    : "Self-destruct armed: \(remaining) attempts left.",
                systemImage: "flame.fill"
            )
            .font(.footnote)
            .foregroundStyle(remaining <= 2 ? .red : .orange)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var passwordEntry: some View {
        SecureField("Master password", text: $password)
            .accessibilityIdentifier("lock.password")
            .textFieldStyle(.roundedBorder)
            .submitLabel(.go)
            .focused($passwordFocused)
            .onSubmit(unlock)
            .disabled(isUnlocking)
            .padding(.horizontal, 40)
            .padding(.top, 26)

        Button(action: unlock) {
            if isUnlocking {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Unlock").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(password.isEmpty || isUnlocking)
        .padding(.horizontal, 40)
        .padding(.top, 14)

        // Always a way back to biometrics: a cancelled or failed attempt used
        // to strand you on the password field until the app was relaunched.
        if model.canUnlockWithBiometrics {
            Button(action: unlockWithBiometrics) {
                Label("Unlock with \(model.biometryName)", systemImage: biometrySymbol)
            }
            .disabled(isUnlocking)
            .padding(.top, 16)
            .accessibilityIdentifier("lock.biometrics")
        }
    }

    private var biometrySymbol: String {
        switch model.biometryName {
        case "Face ID": "faceid"
        case "Optic ID": "opticid"
        default: "touchid"
        }
    }

    private func armIfNeeded() {
        // Someone part-way through typing the password is not asking to be
        // interrupted by the prompt.
        guard !armed, model.canUnlockWithBiometrics, password.isEmpty else { return }
        armed = true
        UnlockTrace.mark("armed")
        unlockWithBiometrics()
    }

    private func unlock() {
        guard !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        errorMessage = nil
        let attempt = password
        Task {
            defer { isUnlocking = false }
            do {
                try await model.unlock(password: attempt)
                password = ""
            } catch VaultError.wrongPassword {
                errorMessage = "Wrong password."
                password = ""
                passwordFocused = true
            } catch VaultError.tampered {
                errorMessage = "Your password was accepted, but the vault data is damaged. Restore a backup you trust."
                password = ""
            } catch VaultError.vaultNotFound {
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func unlockWithBiometrics() {
        guard !isUnlocking else { return }
        isUnlocking = true
        errorMessage = nil
        Task {
            defer { isUnlocking = false }
            do {
                try await model.unlockWithBiometrics()
            } catch BiometricError.cancelled {
                // Cancelling biometrics is how you ask for the password.
                showingPasswordField = true
                passwordFocused = true
            } catch BiometricError.interrupted {
                // The system tore the prompt down — a notification pulled
                // over it, say. Nobody chose the password; the Unlock button
                // is still there, and the next return prompts again.
            } catch BiometricError.notEnrolled {
                showingPasswordField = true
                errorMessage = "\(model.biometryName) needs setting up again in Settings."
            } catch {
                showingPasswordField = true
                errorMessage = "\(model.biometryName) unlock failed — use your password."
            }
        }
    }
}

/// The app icon with the lock badge iOS hangs on a locked app.
private struct LockedAppIcon: View {
    var size: CGFloat

    var body: some View {
        AppIconMark(size: size)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(Color(.systemGray))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .offset(x: size * 0.3, y: size * 0.12)
            }
            .accessibilityHidden(true)
    }
}
