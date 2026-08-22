import SwiftUI
import SafeKeyCore

struct SelfDestructSettingsView: View {
    let session: VaultSession

    @State private var showingArmConfirmation = false
    @State private var confirmationText = ""

    private var policy: SelfDestructPolicy { session.header.selfDestruct }

    var body: some View {
        Form {
            Section {
                Toggle("Erase the vault after failed unlock attempts", isOn: armedBinding)
                if policy.enabled {
                    Stepper(value: attemptsBinding, in: 3...10) {
                        LabeledContent("Wrong attempts before erase") {
                            Text("\(policy.maxAttempts)")
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Label("Self-Destruct", systemImage: "flame.fill")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When triggered, SafeKey deletes every stored copy of the vault key (including the Touch ID copy) and the encrypted vault file, then returns to the setup screen. What is erased here cannot be recovered from this Mac — by anyone.")
                    if session.settings.cloudSyncEnabled {
                        Text("With iCloud sync on, that means this Mac. The copy in iCloud and the one on your other devices are left alone — on purpose: otherwise someone who takes a device could destroy your vault everywhere simply by failing to unlock it. Turn sync off first if you want an erase to be the end of it.")
                            .foregroundStyle(.orange)
                    }
                    Text("Honest limits: this protects against someone guessing at this app. It cannot stop an attacker who copied the vault file beforehand — there, your password strength and the slow key-derivation are the defense.")
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Arm Self-Destruct?", isPresented: $showingArmConfirmation) {
            TextField("Type ERASE to confirm", text: $confirmationText)
            Button("Cancel", role: .cancel) { confirmationText = "" }
            Button("Arm", role: .destructive) {
                if confirmationText == "ERASE" {
                    setPolicy(enabled: true)
                }
                confirmationText = ""
            }
        } message: {
            Text("After \(policy.maxAttempts) wrong password attempts the vault is permanently erased. Type ERASE to confirm.")
        }
    }

    private var armedBinding: Binding<Bool> {
        Binding(
            get: { policy.enabled },
            set: { enable in
                if enable {
                    showingArmConfirmation = true
                } else {
                    setPolicy(enabled: false)
                }
            }
        )
    }

    private var attemptsBinding: Binding<Int> {
        Binding(
            get: { policy.maxAttempts },
            set: { newValue in
                session.updateHeader { $0.selfDestruct.maxAttempts = newValue }
            }
        )
    }

    private func setPolicy(enabled: Bool) {
        session.updateHeader { $0.selfDestruct.enabled = enabled }
    }
}
