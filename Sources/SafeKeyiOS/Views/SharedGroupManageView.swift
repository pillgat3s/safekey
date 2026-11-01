import SwiftUI
import SafeKeyCore

/// A shared group's own screen: who is in it, what it is called, and the way
/// out — deleting it for the owner, leaving it for everyone else.
struct SharedGroupManageView: View {
    let session: VaultSession
    let groupID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var members = SharedGroupMembers()
    @State private var name = ""
    @State private var showingInvite = false
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false

    private var group: WalletGroup? { session.group(id: groupID) }
    private var membership: SharedGroupMembership? { session.membership(for: groupID) }
    private var isOwner: Bool { membership?.isOwner ?? false }
    private var walletCount: Int { session.entries.filter { $0.groupID == groupID }.count }

    var body: some View {
        NavigationStack {
            if let group, let membership {
                Form {
                    Section {
                        VStack(spacing: 10) {
                            SharedGroupMark(size: 64)
                            Text(group.name)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                            Text("\(walletCount) \(walletCount == 1 ? "wallet" : "wallets")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }

                    if isOwner {
                        Section("Group Name") {
                            TextField("Group Name", text: $name)
                                .accessibilityIdentifier("sharedGroup.rename")
                                .submitLabel(.done)
                                .onSubmit(commitRename)
                        }
                    }

                    Section {
                        if members.isLoading && members.members.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading…").foregroundStyle(.secondary)
                            }
                        } else if let error = members.error, members.members.isEmpty {
                            Text(error).foregroundStyle(.secondary)
                        }
                        ForEach(members.members) { member in
                            HStack {
                                Text(member.name)
                                Spacer()
                                Text(member.isOwner ? "Owner" : member.isPending ? "Invited" : "Member")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if isOwner {
                            Button {
                                showingInvite = true
                            } label: {
                                Label("Add or Remove People…", systemImage: "person.badge.plus")
                            }
                            .accessibilityIdentifier("sharedGroup.managePeople")
                        }
                    } header: {
                        Text("Members")
                    } footer: {
                        if isOwner {
                            Text("Everyone here can see, edit and move the group's wallets. Only you can change who is in it.")
                        } else {
                            Text("Everyone here can see, edit and move the group's wallets. Only the owner can change who is in it.")
                        }
                    }

                    Section {
                        if isOwner {
                            Button("Delete Group", role: .destructive) { confirmingDelete = true }
                                .accessibilityIdentifier("sharedGroup.delete")
                        } else {
                            Button("Leave Group", role: .destructive) { confirmingLeave = true }
                                .accessibilityIdentifier("sharedGroup.leave")
                        }
                    } footer: {
                        if isOwner {
                            Text("Deleting the group keeps its wallets in your vault and removes them from everyone else's.")
                        } else {
                            Text("Leaving removes the group's wallets from this device. The other members keep them.")
                        }
                    }
                }
                .navigationTitle("Manage Group")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            commitRename()
                            dismiss()
                        }
                        .accessibilityIdentifier("sharedGroup.done")
                    }
                }
                .task(id: membership.id) {
                    name = group.name
                    await members.load(membership: membership, name: group.name, service: model.cloudSharing)
                }
                .sheet(isPresented: $showingInvite, onDismiss: {
                    Task { await members.load(membership: membership, name: group.name, service: model.cloudSharing) }
                }) {
                    SharedGroupInviteSheet(session: session, group: group)
                }
                .confirmationDialog(
                    "Delete “\(group.name)”?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete Group", role: .destructive) {
                        session.deleteSharedGroup(id: groupID)
                        dismiss()
                    }
                } message: {
                    Text("Its wallets stay in your vault, under My Wallets. Everyone else in the group loses them.")
                }
                .confirmationDialog(
                    "Leave “\(group.name)”?",
                    isPresented: $confirmingLeave,
                    titleVisibility: .visible
                ) {
                    Button("Leave Group", role: .destructive) {
                        session.leaveSharedGroup(id: groupID)
                        dismiss()
                    }
                } message: {
                    Text("The group's wallets are removed from this device. You will need a new invitation to rejoin.")
                }
            } else {
                ContentUnavailableView {
                    Label("Group Not Found", systemImage: "person.2.slash")
                } description: {
                    Text("This group is no longer in the vault.")
                } actions: {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func commitRename() {
        guard isOwner, var group else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else { return }
        group.name = trimmed
        session.updateGroup(group)
    }
}
