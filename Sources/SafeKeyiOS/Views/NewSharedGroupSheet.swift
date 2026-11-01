import SwiftUI
import SafeKeyCore

/// Creating a shared group, in the steps the Passwords app uses: name it,
/// add people, then choose which wallets to move in.
///
/// The group exists in iCloud from the moment Create is tapped — its zone is
/// made first, so there is somewhere for the wallets to go — and the next two
/// steps can each be skipped and done later from the group's Manage screen.
struct NewSharedGroupSheet: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case name
        case people(WalletGroup)
        case move(WalletGroup)
    }

    @State private var step: Step = .name
    @State private var name = ""
    @State private var isCreating = false
    @State private var failure: String?
    @State private var showingInvite = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        session.sharedGroups.contains { $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            switch step {
            case .name:
                nameStep
            case .people(let group):
                peopleStep(group)
            case .move(let group):
                MoveWalletsView(session: session, group: group) { dismiss() }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    // MARK: - Name

    private var nameStep: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    SharedGroupMark(size: 64)
                    Text("Everyone in the group can see and edit the wallets in it. Only you can add or remove people, rename the group, or delete it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Group Name", text: $name, prompt: Text("e.g. Ops Team"))
                    .accessibilityIdentifier("sharedGroup.name")
                    .submitLabel(.done)
                    .onSubmit { if canCreate { create() } }
            } footer: {
                if nameIsTaken {
                    Text("There is already a shared group with that name.")
                        .foregroundStyle(.red)
                } else if let failure {
                    Text(failure).foregroundStyle(.red)
                } else {
                    Text("Wallets you move into the group leave your own vault and are shared with its members. Keep anything that is yours alone out of it.")
                }
            }
        }
        .navigationTitle("New Shared Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isCreating)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isCreating {
                    ProgressView()
                } else {
                    Button("Create") { create() }
                        .disabled(!canCreate)
                        .accessibilityIdentifier("sharedGroup.create")
                }
            }
        }
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && !nameIsTaken && !isCreating
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        failure = nil
        Task {
            do {
                let group = try await model.sync.createSharedGroup(name: trimmedName, session: session)
                step = .people(group)
            } catch {
                failure = error.localizedDescription
            }
            isCreating = false
        }
    }

    // MARK: - People

    private func peopleStep(_ group: WalletGroup) -> some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SharedGroupMark(size: 64)
                    Text(group.name)
                        .font(.title2.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                HStack {
                    Text("You")
                    Spacer()
                    Text("Owner").foregroundStyle(.secondary)
                }
                Button {
                    showingInvite = true
                } label: {
                    Label("Add People…", systemImage: "person.badge.plus")
                }
                .accessibilityIdentifier("sharedGroup.addPeople")
            } header: {
                Text("Group Members")
            } footer: {
                Text("People you invite get a link through Messages, Mail, or any app you choose. They need SafeKey and an iCloud account, and they see the group's wallets as soon as they accept.")
            }
        }
        .navigationTitle("Add People")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") { step = .move(group) }
                    .accessibilityIdentifier("sharedGroup.next")
            }
        }
        .sheet(isPresented: $showingInvite) {
            SharedGroupInviteSheet(session: session, group: group)
        }
    }
}

/// Picking the wallets to move into a shared group — the step after creating
/// one, and the way the Passwords app fills a new group.
struct MoveWalletsView: View {
    let session: VaultSession
    let group: WalletGroup
    /// Called when the step is over, moved or not.
    let onDone: () -> Void

    @State private var selected: Set<WalletEntry.ID> = []

    /// Only wallets that are the user's own are offered. A wallet already in
    /// another shared group is moved from that group's own screen, where it
    /// is clear whose it is being taken from.
    private var candidates: [WalletEntry] {
        session.settings.sorted(session.ownEntries)
    }

    var body: some View {
        Group {
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to Move", systemImage: "key.slash")
                } description: {
                    Text("Add a wallet to the vault first, or move one into “\(group.name)” from its own screen later.")
                }
            } else {
                List(selection: $selected) {
                    Section {
                        ForEach(candidates) { entry in
                            EntryRow(entry: entry, groupName: session.group(id: entry.groupID)?.name)
                                .tag(entry.id)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Move Wallets to “\(group.name)”?")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text("Choose the wallets to share with the group. Everyone in it will be able to see and use them.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .padding(.bottom, 6)
                    }
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Move Wallets")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Now") { onDone() }
                    .accessibilityIdentifier("sharedGroup.notNow")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(selected.count > 1 ? "Move \(selected.count)" : "Move") {
                    session.move(entryIDs: Array(selected), toGroup: group.id)
                    onDone()
                }
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("sharedGroup.move")
            }
        }
    }
}
