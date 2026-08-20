import SwiftUI
import SafeKeyCore

struct SetPasswordStepView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var strength: PasswordStrength.Level { PasswordStrength.evaluate(password) }

    private var canCreate: Bool {
        strength != .tooShort && password == confirmation && !isCreating
    }

    var body: some View {
        GlassCard {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Choose a Master Password")
                    .font(.title2.bold())
                Text("This password encrypts everything. It is never stored anywhere — if you forget it, the vault cannot be recovered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                VStack(spacing: 10) {
                    SecureField("Master password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    PasswordStrengthMeter(password: password)
                    SecureField("Confirm password", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canCreate { create() } }
                    if !confirmation.isEmpty && confirmation != password {
                        Text("Passwords don't match")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 320)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 120)
                    } else {
                        Text("Create Vault")
                            .frame(minWidth: 120)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canCreate)
            }
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let chosen = password
        Task {
            do {
                try await model.createVault(password: chosen)
            } catch {
                errorMessage = "Could not create the vault: \(error.localizedDescription)"
                isCreating = false
            }
        }
    }
}
