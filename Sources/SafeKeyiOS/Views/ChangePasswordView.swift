import SwiftUI
import SafeKeyCore

/// Changing the master password re-wraps the data key; it never re-encrypts the
/// entries and never invalidates the Face ID copy of the key.
struct ChangePasswordView: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var updated = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var strength: PasswordStrength.Level { PasswordStrength.evaluate(updated) }

    private var canSubmit: Bool {
        !current.isEmpty
            && strength != .tooShort
            && updated == confirmation
            && updated != current
            && !isWorking
    }

    var body: some View {
        Form {
            Section("Current Password") {
                SecureField("Current password", text: $current)
                    .textContentType(.password)
            }

            Section {
                SecureField("New password", text: $updated)
                    .textContentType(.newPassword)
                PasswordStrengthMeter(password: updated)
                SecureField("Confirm new password", text: $confirmation)
                    .textContentType(.newPassword)
                if !confirmation.isEmpty, confirmation != updated {
                    Text("Passwords don't match")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !updated.isEmpty, updated == current {
                    Text("Choose a password different from the current one.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("New Password")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your wallets are not re-encrypted — only the key that protects them is re-wrapped, so this is instant. Any backup you exported earlier still opens with the password it had when you saved it.")
                    if session.settings.cloudSyncEnabled {
                        Text("This changes the password on this iPhone. Your other devices keep the one they already have and go on syncing — the wallets travel sealed under a key that a password change does not touch. Change it there too if you meant to retire the old one everywhere.")
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }

            Section {
                Button {
                    submit()
                } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Change Password").frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("Master Password")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isWorking)
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.changePassword(old: current, new: updated)
                dismiss()
            } catch VaultError.wrongPassword {
                errorMessage = "That is not your current password."
                current = ""
            } catch {
                errorMessage = "Could not change the password: \(error.localizedDescription)"
            }
        }
    }
}
