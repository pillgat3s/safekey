import SwiftUI
import SafeKeyCore

/// Creating a group from the home screen.
///
/// A group belongs to one chain, so the chain is part of creating it rather
/// than something to fix afterwards — a folder spanning Solana and Bitcoin
/// wallets has no meaning.
struct NewGroupSheet: View {
    let session: VaultSession
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var chain: Chain = .evm
    @State private var showingChainPicker = false
    @State private var icon: String?
    @State private var colorHex: String? = WalletGroup.palette.first

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        session.groups(for: chain)
            .contains { $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        GroupMark(
                            group: WalletGroup(name: name, chain: chain, colorHex: colorHex, icon: icon),
                            size: 30
                        )
                        TextField("Name", text: $name, prompt: Text("e.g. Cold Storage"))
                            .accessibilityIdentifier("group.name")
                    }
                    Button {
                        showingChainPicker = true
                    } label: {
                        HStack {
                            Text("Chain").foregroundStyle(.primary)
                            Spacer()
                            ChainLogo(chain: chain, size: 22)
                            Text(chain.displayName).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if nameIsTaken {
                        Text("There is already a group with that name on \(chain.displayName).")
                            .foregroundStyle(.red)
                    } else {
                        Text("Groups organise wallets within one chain.")
                    }
                }
                GroupIconPicker(icon: $icon, colorHex: $colorHex)
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        _ = session.addGroup(
                            name: trimmedName,
                            chain: chain,
                            colorHex: colorHex,
                            icon: icon
                        )
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || nameIsTaken)
                }
            }
            .sheet(isPresented: $showingChainPicker) {
                ChainPickerView(selection: $chain)
            }
            .onAppear { chain = session.settings.defaultChain }
        }
    }
}
