import SwiftUI
import SafeKeyCore

/// Rename and delete groups. Creating one happens where it is needed — in the
/// wallet editor — so this is the tidying-up screen.
///
/// Groups are listed under their chain because that is what they are scoped to:
/// a folder spanning Solana and Bitcoin wallets has no meaning.
struct GroupsView: View {
    let session: VaultSession

    @State private var renaming: WalletGroup?
    @State private var renameText = ""
    @State private var pendingDeletion: WalletGroup?

    private var chains: [Chain] {
        var seen: [Chain] = []
        for group in session.groups where !seen.contains(group.chain) {
            seen.append(group.chain)
        }
        return seen.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        Group {
            if session.groups.isEmpty {
                ContentUnavailableView {
                    Label("No Groups", systemImage: "folder")
                } description: {
                    Text("Create a group while adding or editing a wallet, then organise wallets within that chain.")
                }
            } else {
                List {
                    ForEach(chains, id: \.self) { chain in
                        Section {
                            ForEach(session.groups(for: chain)) { group in
                                row(for: group)
                            }
                        } header: {
                            HStack(spacing: 8) {
                                ChainLogo(chain: chain, size: 18)
                                Text(chain.displayName)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Group", isPresented: renameBinding) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { commitRename() }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if let group = pendingDeletion { session.deleteGroup(id: group.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("The wallets in it are kept — they just stop belonging to a group.")
        }
    }

    private func row(for group: WalletGroup) -> some View {
        let count = session.entries.filter { $0.groupID == group.id }.count
        return HStack {
            Text(group.name)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            renameText = group.name
            renaming = group
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = group
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private func commitRename() {
        guard var group = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        group.name = name
        session.updateGroup(group)
    }
}
