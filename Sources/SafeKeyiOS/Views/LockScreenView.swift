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
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "key.radiowaves.forward.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.bottom, 22)

            Text("SafeKey Is Locked")
                .font(.title2.bold())

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 6)

            SecureField("Master password", text: $password)
                .accessibilityIdentifier("lock.password")
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($passwordFocused)
                .onSubmit(unlock)
                .disabled(isUnlocking)
                .padding(.horizontal, 40)
                .padding(.top, 24)

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

            Button(action: unlock) {
                if isUnlocking {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Unlock").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(password.isEmpty || isUnlocking)
            .padding(.horizontal, 40)
            .padding(.top, 18)

            if model.canUnlockWithBiometrics {
                Button {
                    unlockWithBiometrics()
                } label: {
                    Label("Unlock with \(model.biometryName)", systemImage: biometrySymbol)
                }
                .padding(.top, 14)
                .disabled(isUnlocking)
            }

            Spacer()
            Spacer()
        }
        .task {
            guard model.canUnlockWithBiometrics, !didOfferBiometrics else { return }
            didOfferBiometrics = true
            unlockWithBiometrics()
        }
    }

    private var biometrySymbol: String {
        model.biometryName == "Face ID" ? "faceid" : "touchid"
    }

    private var subtitle: String {
        model.canUnlockWithBiometrics
            ? "Use \(model.biometryName) or enter your master password."
            : "Enter your master password to unlock."
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
                passwordFocused = true
            } catch BiometricError.notEnrolled {
                errorMessage = "\(model.biometryName) needs setting up again in Settings."
            } catch {
                errorMessage = "\(model.biometryName) unlock failed — use your password."
            }
        }
    }
}
