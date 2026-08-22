import SwiftUI
import SafeKeyCore

struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !currentPassword.isEmpty
            && PasswordStrength.evaluate(newPassword) != .tooShort
            && newPassword == confirmation
            && !isWorking
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Change Master Password")
                .font(.title3.bold())

            VStack(spacing: 10) {
                SecureField("Current password", text: $currentPassword)
                SecureField("New password", text: $newPassword)
                PasswordStrengthMeter(password: newPassword)
                SecureField("Confirm new password", text: $confirmation)
                if !confirmation.isEmpty && confirmation != newPassword {
                    Text("Passwords don't match")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textFieldStyle(.roundedBorder)

            if model.session?.settings.cloudSyncEnabled == true {
                Text("This changes the password on this Mac. Your other devices keep the one they already have and go on syncing — the wallets travel sealed under a key that a password change does not touch. Change it there too if you meant to retire the old one everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    submit()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).frame(minWidth: 70)
                    } else {
                        Text("Change").frame(minWidth: 70)
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.changePassword(old: currentPassword, new: newPassword)
                dismiss()
            } catch VaultError.wrongPassword {
                errorMessage = "Current password is incorrect."
                isWorking = false
            } catch VaultError.deviceKeyRequired {
                errorMessage = "Insert your security key first."
                isWorking = false
            } catch {
                errorMessage = "Could not change the password: \(error.localizedDescription)"
                isWorking = false
            }
        }
    }
}
