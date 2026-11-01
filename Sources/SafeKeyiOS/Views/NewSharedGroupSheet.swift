import SwiftUI
import SafeKeyCore

/// Creating a shared group, in the steps the Passwords app uses: a page that
/// says what sharing means, then the group's name and people on one form
/// created with the checkmark, then the wallets to move in.
///
/// People can be invited before the group is "created": CloudKit needs the
/// zone to exist for an invitation, so the first tap on Add People makes the
/// zone under the name typed so far, and the checkmark only settles the name.
/// Cancelling after that takes the zone away again.
struct NewSharedGroupSheet: View {
    let session: VaultSession
    /// Set by a wallet's own screen: the group is for that wallet, so the
    /// move step is skipped and the caller puts the wallet in.
    var onCreated: ((WalletGroup) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case intro
        case create
        case move(WalletGroup)
    }

    @State private var step: Step = .intro
    @State private var name = ""
    @State private var created: WalletGroup?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var showingInvite = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        session.sharedGroups.contains {
            $0.id != created?.id && $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            switch step {
            case .intro:
                intro
            case .create:
                createForm
            case .move(let group):
                MoveWalletsView(session: session, group: group) { dismiss() }
            }
        }
        .interactiveDismissDisabled(isWorking || created != nil)
    }

    // MARK: - What sharing means

    private var intro: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            SharedGroupMark(size: 88)
            Text("Share Wallets With People You Trust")
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.horizontal, 32)
            VStack(alignment: .leading, spacing: 22) {
                introRow(
                    "person.2.fill",
                    title: "Everyone Can Use Them",
                    text: "People in the group see the wallets you move in, and can edit them or add their own."
                )
                introRow(
                    "lock.fill",
                    title: "Encrypted End to End",
                    text: "The group's wallets are sealed under a key made for the group. Your vault's own key is never shared."
                )
                introRow(
                    "hand.raised.fill",
                    title: "You Stay in Control",
                    text: "Only you can add or remove people, rename the group, or delete it. Keep anything that is yours alone out of it."
                )
            }
            .padding(.top, 34)
            .padding(.horizontal, 32)
            Spacer()
            Button {
                step = .create
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("sharedGroup.continue")
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel")
            }
        }
    }

    private func introRow(_ symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Name and people

    private var canCreate: Bool {
        !trimmedName.isEmpty && !nameIsTaken && !isWorking
    }

    private var createForm: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    SharedGroupMark(size: 64)
                    TextField("Group Name", text: $name, prompt: Text("Group Name"))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                        .accessibilityIdentifier("sharedGroup.name")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            } footer: {
                if nameIsTaken {
                    Text("There is already a shared group with that name.")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
            }
            Section {
                HStack {
                    Text("You")
                    Spacer()
                    Text("Owner").foregroundStyle(.secondary)
                }
                Button {
                    addPeople()
                } label: {
                    Label("Add People…", systemImage: "person.badge.plus")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("sharedGroup.addPeople")
            } header: {
                Text("Group Members")
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else {
                    Text("People you invite get a link through Messages, Mail, or any app you choose. They need SafeKey and an iCloud account, and they see the group's wallets as soon as they accept.")
                }
            }
        }
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
        .navigationTitle("New Shared Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { cancel() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel")
                    .disabled(isWorking)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button { create() } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Create")
                        .accessibilityIdentifier("sharedGroup.create")
                        .disabled(!canCreate)
                }
            }
        }
        .sheet(isPresented: $showingInvite) {
            if let created {
                SharedGroupInviteSheet(session: session, group: created)
            }
        }
    }

    /// Makes the group in iCloud if it does not exist yet, under the name
    /// typed so far, so there is something to invite people to.
    private func ensureCreated() async -> WalletGroup? {
        if let created { return created }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let group = try await model.sync.createSharedGroup(
                name: trimmedName.isEmpty ? SharedGroupPartition.placeholderName : trimmedName,
                session: session
            )
            created = group
            return group
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    private func addPeople() {
        Task {
            guard await ensureCreated() != nil else { return }
            showingInvite = true
        }
    }

    private func create() {
        guard canCreate else { return }
        Task {
            guard var group = await ensureCreated() else { return }
            if group.name != trimmedName {
                group.name = trimmedName
                session.updateGroup(group)
            }
            if let onCreated {
                onCreated(group)
                dismiss()
            } else {
                step = .move(group)
            }
        }
    }

    /// Cancelling after people were invited takes the group away again: a
    /// group that was never created should not be left behind in iCloud.
    private func cancel() {
        if let created {
            session.deleteSharedGroup(id: created.id)
        }
        dismiss()
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
                .buttonStyle(.glassProminent)
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("sharedGroup.move")
            }
        }
    }
}
