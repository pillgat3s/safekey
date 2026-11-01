import SwiftUI
import SafeKeyCore

/// Creating one of the vault's own groups — a folder within one chain.
///
/// Reached from a wallet's Group row, so the chain is already known and the
/// wallet goes into the new group straight away. A folder spanning Solana
/// and Bitcoin wallets has no meaning, which is why the chain is fixed here
/// rather than something to change afterwards.
struct NewGroupSheet: View {
    let session: VaultSession
    /// The chain the group is for; the vault's default when not given.
    var chain: Chain?
    /// Told about the group once it exists, so the caller can put a wallet in.
    var onCreate: ((WalletGroup) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedChain: Chain = .evm
    @State private var showingChainPicker = false
    @State private var icon: String?
    @State private var colorHex: String? = WalletGroup.palette.first
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        session.groups(for: selectedChain)
            .contains { $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        GroupMark(
                            group: WalletGroup(name: name, chain: selectedChain, colorHex: colorHex, icon: icon),
                            size: 30
                        )
                        TextField("Name", text: $name, prompt: Text("e.g. Cold Storage"))
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .accessibilityIdentifier("group.name")
                    }
                    Button {
                        showingChainPicker = true
                    } label: {
                        HStack {
                            Text("Chain").foregroundStyle(.primary)
                            Spacer()
                            ChainLogo(chain: selectedChain, size: 22)
                            Text(selectedChain.displayName).foregroundStyle(.secondary)
                        }
                    }
                    // Fixed when the group is for a wallet whose chain is known.
                    .disabled(chain != nil)
                } footer: {
                    if nameIsTaken {
                        Text("There is already a group with that name on \(selectedChain.displayName).")
                            .foregroundStyle(.red)
                    } else {
                        Text("Groups organise wallets within one chain.")
                    }
                }
                GroupIconPicker(icon: $icon, colorHex: $colorHex)
            }
            .defaultFocus($nameFocused, true)
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let group = session.addGroup(
                            name: trimmedName,
                            chain: selectedChain,
                            colorHex: colorHex,
                            icon: icon
                        )
                        onCreate?(group)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Create")
                    .disabled(trimmedName.isEmpty || nameIsTaken)
                }
            }
            .sheet(isPresented: $showingChainPicker) {
                ChainPickerView(selection: $selectedChain)
            }
            .onAppear {
                selectedChain = chain ?? session.settings.defaultChain
                nameFocused = true
            }
        }
    }
}
