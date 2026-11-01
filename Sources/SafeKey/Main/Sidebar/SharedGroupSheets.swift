import SwiftUI
import SafeKeyCore

/// Creating a shared group on the Mac: name it, then invite people through
/// the system's sharing sheet. Wallets are moved in afterwards from the list
/// — "Move to Group" on a wallet, or the Group picker on its own screen.
struct NewSharedGroupView: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var created: WalletGroup?
    @State private var isCreating = false
    @State private var failure: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameIsTaken: Bool {
        session.sharedGroups.contains { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    private var canCreate: Bool { !trimmed.isEmpty && !nameIsTaken && !isCreating }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SharedGroupMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(created == nil ? "New Shared Group" : created!.name)
                        .font(.title3.bold())
                    Text(created == nil
                         ? "Everyone in the group can see and edit its wallets."
                         : "Invite people now, or later from the group's Manage screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if created == nil {
                TextField("Name", text: $name, prompt: Text("e.g. Ops Team"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canCreate { create() } }
                if nameIsTaken {
                    Text("There is already a shared group with that name.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Wallets you move into the group leave your own vault and are shared with its members. Only you can add or remove people, rename the group, or delete it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    invite()
                } label: {
                    Label("Add People…", systemImage: "person.badge.plus")
                }
                Text("People you invite get a link through Messages, Mail, or any app you choose. They need SafeKey and an iCloud account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if created == nil {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isCreating)
                }
                Spacer()
                if created == nil {
                    Button("Create") { create() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        failure = nil
        Task {
            do {
                created = try await model.sync.createSharedGroup(name: trimmed, session: session)
            } catch {
                failure = error.localizedDescription
            }
            isCreating = false
        }
    }

    private func invite() {
        guard let created, let membership = session.membership(for: created.id) else { return }
        guard let service = model.cloudSharing else {
            failure = "Inviting people needs iCloud, which this build is running without."
            return
        }
        Task {
            do {
                try await CloudSharingPresenter.present(membership: membership, name: created.name, service: service)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A shared group's own sheet: who is in it, what it is called, and the way
/// out — deleting it for the owner, leaving it for everyone else.
struct SharedGroupManageView: View {
    let session: VaultSession
    let groupID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var members = SharedGroupMembers()
    @State private var name = ""
    @State private var failure: String?
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false

    private var group: WalletGroup? { session.group(id: groupID) }
    private var membership: SharedGroupMembership? { session.membership(for: groupID) }
    private var isOwner: Bool { membership?.isOwner ?? false }
    private var walletCount: Int { session.entries.filter { $0.groupID == groupID }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let group, let membership {
                HStack(spacing: 12) {
                    SharedGroupMark(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.title3.bold())
                        Text("\(walletCount) \(walletCount == 1 ? "wallet" : "wallets") · \(isOwner ? "you own this group" : "shared with you")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isOwner {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitRename)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if members.isLoading && members.members.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
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
                            managePeople(group: group, membership: membership)
                        } label: {
                            Label("Add or Remove People…", systemImage: "person.badge.plus")
                        }
                        .padding(.top, 4)
                    }
                }

                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    if isOwner {
                        Button("Delete Group…", role: .destructive) { confirmingDelete = true }
                    } else {
                        Button("Leave Group…", role: .destructive) { confirmingLeave = true }
                    }
                    Spacer()
                    Button("Done") {
                        commitRename()
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("This group is no longer in the vault.")
                Button("Done") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 400)
        .task(id: groupID) {
            guard let group, let membership else { return }
            name = group.name
            await members.load(membership: membership, name: group.name, service: model.cloudSharing)
        }
        .confirmationDialog(
            "Delete “\(group?.name ?? "")”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                session.deleteSharedGroup(id: groupID)
                dismiss()
            }
        } message: {
            Text("Its wallets stay in your vault. Everyone else in the group loses them.")
        }
        .confirmationDialog(
            "Leave “\(group?.name ?? "")”?",
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                session.leaveSharedGroup(id: groupID)
                dismiss()
            }
        } message: {
            Text("The group's wallets are removed from this Mac. You will need a new invitation to rejoin.")
        }
    }

    private func commitRename() {
        guard isOwner, var group else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else { return }
        group.name = trimmed
        session.updateGroup(group)
    }

    private func managePeople(group: WalletGroup, membership: SharedGroupMembership) {
        guard let service = model.cloudSharing else {
            failure = "Inviting people needs iCloud, which this build is running without."
            return
        }
        Task {
            do {
                try await CloudSharingPresenter.present(membership: membership, name: group.name, service: service)
                await members.load(membership: membership, name: group.name, service: service)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
