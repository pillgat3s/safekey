import SwiftUI
import LocalAuthentication
import SafeKeyCore

/// Lock screen. Face ID is *armed* whenever this is showing and the app is
/// active, because the sensor only responds while an evaluation is pending —
/// there is no passive mode.
struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var didOfferBiometrics = false
    @State private var showingPasswordField = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AppIconMark(size: 88)

            Text("SafeKey Is Locked")
                .font(.title2.bold())
                .padding(.top, 20)

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

            if showingPasswordField || !model.canUnlockWithBiometrics {
                SecureField("Master password", text: $password)
                    .accessibilityIdentifier("lock.password")
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($passwordFocused)
                    .onSubmit(unlock)
                    .disabled(isUnlocking)
                    .padding(.horizontal, 40)
                    .padding(.top, 22)

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

                // Always a way back to biometrics: a cancelled or failed
                // attempt used to strand you on the password field until the
                // app was relaunched.
                if model.canUnlockWithBiometrics {
                    Button {
                        unlockWithBiometrics()
                    } label: {
                        Label("Unlock with \(model.biometryName)", systemImage: biometrySymbol)
                    }
                    .disabled(isUnlocking)
                    .padding(.top, 16)
                    .accessibilityIdentifier("lock.biometrics")
                }
            } else {
                // Biometrics is the primary way in; the password is the fallback
                // behind it, the way iOS presents a locked app.
                Button {
                    unlockWithBiometrics()
                } label: {
                    Text("Unlock").frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(isUnlocking)
                .padding(.top, 22)
                .accessibilityIdentifier("lock.biometrics")

                Button("Enter Master Password") {
                    showingPasswordField = true
                    passwordFocused = true
                }
                .font(.subheadline)
                .padding(.top, 14)
            }

            Spacer()
            Spacer()
        }
        // A single column rather than controls stretched across the full
        // width: without this a landscape iPhone — and any iPad — renders a
        // password field the width of the screen.
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .task {
            guard model.canUnlockWithBiometrics, !didOfferBiometrics else { return }
            didOfferBiometrics = true
            unlockWithBiometrics()
        }
    }

    private var biometrySymbol: String {
        switch model.biometryName {
        case "Face ID": "faceid"
        case "Optic ID": "opticid"
        default: "touchid"
        }
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
            } catch BiometricError.cancelled, BiometricError.interrupted {
                // Cancelling biometrics is how you ask for the password.
                showingPasswordField = true
                passwordFocused = true
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
