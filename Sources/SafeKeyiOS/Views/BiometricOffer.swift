import SwiftUI
import SafeKeyCore

/// Asks once whether to unlock with Face ID: right after the vault is
/// created, and again when a different vault takes this device's place —
/// adopted from iCloud, or restored from a backup. The enrolment is keyed to
/// the vault it was made for, so it does not carry over, and without the
/// question the newcomer left people typing the password on every open.
/// Held back while a sheet is up so the alert never competes with one.
struct BiometricOffer: ViewModifier {
    let session: VaultSession
    let sheetsPresented: Bool
    @Environment(AppModel.self) private var model
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task(id: session.header.vaultID) { offerIfDue() }
            .onChange(of: sheetsPresented) { _, presented in
                guard !presented else { return }
                // Let the sheet finish leaving before anything else presents.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    offerIfDue()
                }
            }
            .alert("Unlock with \(model.biometryName)?", isPresented: $showing) {
                Button("Not Now", role: .cancel) {}
                Button("Use \(model.biometryName)") {
                    Task { try? await model.enableBiometricUnlock() }
                }
            } message: {
                Text("You can open SafeKey with \(model.biometryName) instead of typing your master password. You will still need the password after a restart, and you can change this in Settings.")
            }
    }

    private func offerIfDue() {
        guard !sheetsPresented, !showing,
              session.isNewlyCreated || model.biometricOfferPending,
              BiometricFactor.isBiometryAvailable(),
              !model.biometricFactor.isEnrolled(vaultID: session.header.vaultID)
        else { return }
        session.isNewlyCreated = false
        model.clearBiometricOffer()
        showing = true
    }
}
