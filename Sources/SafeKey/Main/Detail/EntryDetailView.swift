import SwiftUI
import SafeKeyCore

/// A wallet's own screen, laid out the same way as the iPhone: the mark and
/// name centred above the facts, so both apps read as one product.
struct EntryDetailView: View {
    let session: VaultSession
    let entry: WalletEntry
    @State private var isEditing = false
    @State private var creatingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ChainLogo(chain: entry.chain, size: 72)
                    Text(entry.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("\(entry.chain.displayName) · \(entry.kind.displayName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                SecretRevealRow(entry: entry, session: session)
            }

            Section {
                if let address = entry.publicAddress, !address.isEmpty {
                    LabeledContent("Public Address") {
                        HStack(spacing: 8) {
                            Text(address)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                            } label: {
                                Image(systemName: "document.on.document")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy address")
                        }
                    }
                }

                LabeledContent("Chain", value: entry.chain.displayName)

                // Moving a wallet between groups from its own screen, the way
                // the iPhone offers it.
                Picker("Group", selection: groupBinding) {
                    Text("None").tag(UUID?.none)
                    ForEach(session.groups(for: entry.chain)) { group in
                        Text(group.name).tag(UUID?.some(group.id))
                    }
                }

                Button("New Group…") {
                    newGroupName = ""
                    creatingGroup = true
                }

                LabeledContent("Favorite") {
                    Toggle("", isOn: favoriteBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if !entry.tags.isEmpty {
                    LabeledContent("Tags") {
                        Text(entry.tags.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent(
                    "Modified",
                    value: entry.modifiedAt.formatted(date: .abbreviated, time: .omitted)
                )
            }

            if !entry.notes.isEmpty {
                Section("Notes") {
                    Text(entry.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            EntryEditView(session: session, existing: entry)
        }
        .alert("New Group", isPresented: $creatingGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { newGroupName = "" }
            Button("Create") { createGroup() }
        } message: {
            Text("Groups organise wallets within \(entry.chain.displayName).")
        }
    }

    private var groupBinding: Binding<UUID?> {
        Binding(
            get: { entry.groupID },
            set: { session.move(entryID: entry.id, toGroup: $0) }
        )
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: { entry.favorite },
            set: { _ in session.toggleFavorite(id: entry.id) }
        )
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        newGroupName = ""
        guard !name.isEmpty else { return }
        let group = session.addGroup(name: name, chain: entry.chain, colorHex: nil)
        session.move(entryID: entry.id, toGroup: group.id)
    }
}
