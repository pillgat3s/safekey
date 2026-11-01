import SwiftUI
import SafeKeyCore

/// The iPad layout: the sidebar arrangement the Passwords app uses there.
///
/// The same categories, chains and groups the iPhone shows as a tile grid,
/// presented as a selectable sidebar with the wallet list beside it. Only ever
/// shown at regular width — an iPad in slide-over falls back to the iPhone
/// layout through the size-class switch in `RootView`.
struct VaultSplitView: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model

    /// One row in the sidebar. Hashable so `List(selection:)` can hold it.
    enum Selection: Hashable {
        case tile(VaultSettings.HomeTile)
        case chain(Chain)
        case group(UUID)
        /// Everything outside the shared groups.
        case myWallets
    }

    @State private var selection: Selection?
    /// Wallets pushed in the detail column, as values, for the same reason the
    /// iPhone home screen keeps its path: to come back after a lock.
    @State private var detailPath: [HomeRoute]

    init(session: VaultSession, resume: ResumeState = ResumeState()) {
        self.session = session
        _selection = State(initialValue: resume.splitSelection ?? .tile(.all))
        _detailPath = State(initialValue: resume.splitPath)
    }
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingNewGroup = false
    @State private var showingNewSharedGroup = false
    @State private var managingGroup: WalletGroup?
    @State private var renamingGroup: WalletGroup?
    @State private var renameText = ""
    @State private var deletingGroup: WalletGroup?
    @State private var leavingGroup: WalletGroup?

    private var visibleTiles: [VaultSettings.HomeTile] {
        let settings = session.settings
        return VaultSettings.ordered(VaultSettings.HomeTile.allCases, by: settings.homeTileOrder)
            .filter { !settings.hiddenHomeTiles.contains($0) }
    }

    private var orderedChains: [Chain] {
        VaultSettings.ordered(session.usedChains, by: session.settings.chainOrder)
    }

    /// Every group in the vault, so a disappearing one is noticed.
    private var groupIDs: Set<UUID> {
        Set(session.unlocked.payload.groups.map(\.id))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detail
        }
        // Both columns side by side, as the Passwords app keeps them: the
        // sidebar is a place to stand, not a drawer that covers the list. On
        // iPhone Duo's inner display the system then sizes the two columns to
        // the fold, so neither straddles it when the device is half open.
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingAdd) {
            EntryEditView(session: session, existing: nil)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(session: session)
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupSheet(session: session)
        }
        .sheet(isPresented: $showingNewSharedGroup) {
            NewSharedGroupSheet(session: session)
        }
        .sheet(item: $managingGroup) { group in
            SharedGroupManageView(session: session, groupID: group.id)
        }
        .onChange(of: selection) { _, current in
            // A different list starts at its root; a wallet pushed over the
            // old one would otherwise stay up over the new.
            detailPath = []
            model.resume.noteSplit(selection: current, path: [])
        }
        .onChange(of: detailPath) { _, current in model.resume.noteSplit(selection: selection, path: current) }
        // A group can go while it is selected — deleted or left from its own
        // Manage screen, or taken away by a sync — and the detail column
        // would otherwise be left on a filter that matches nothing.
        .onChange(of: groupIDs) { _, _ in
            if case .group(let id) = selection, session.group(id: id) == nil {
                selection = .tile(.all)
            }
            let valid = detailPath.validated(in: session)
            if valid.count != detailPath.count { detailPath = valid }
        }
        .modifier(BiometricOffer(
            session: session,
            sheetsPresented: showingSettings || showingAdd || showingNewGroup || showingNewSharedGroup || managingGroup != nil
        ))
        .alert("Rename Group", isPresented: renameBinding) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Save") { commitRename() }
        }
        .confirmationDialog(
            "Delete “\(deletingGroup?.name ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button(deletingGroup.map { session.isShared($0.id) } == true ? "Delete Group" : "Delete", role: .destructive) {
                if let group = deletingGroup {
                    // Leaving a deleted group selected would strand the detail
                    // column on a filter that matches nothing.
                    if selection == .group(group.id) { selection = .tile(.all) }
                    session.deleteGroup(id: group.id)
                }
                deletingGroup = nil
            }
        } message: {
            if deletingGroup.map({ session.isShared($0.id) }) == true {
                Text("Its wallets stay in your vault, under My Wallets. Everyone else in the group loses them.")
            } else {
                Text("The wallets in it are kept — they just stop belonging to a group.")
            }
        }
        .confirmationDialog(
            "Leave “\(leavingGroup?.name ?? "")”?",
            isPresented: Binding(get: { leavingGroup != nil }, set: { if !$0 { leavingGroup = nil } }),
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                if let group = leavingGroup {
                    if selection == .group(group.id) { selection = .tile(.all) }
                    session.leaveSharedGroup(id: group.id)
                }
                leavingGroup = nil
            }
        } message: {
            Text("The group's wallets are removed from this device. You will need a new invitation to rejoin.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(visibleTiles, id: \.self) { tile in
                    let info = tileInfo(tile)
                    Label {
                        Text(info.title)
                    } icon: {
                        Image(systemName: info.icon)
                            .foregroundStyle(info.tint)
                    }
                    .badge(info.count)
                    .tag(Selection.tile(tile))
                }
            }

            if !session.sharedGroups.isEmpty {
                Section("Shared Groups") {
                    Label {
                        Text("My Wallets")
                    } icon: {
                        SharedGroupMark(size: 26, own: true)
                    }
                    .badge(session.ownEntries.count)
                    .tag(Selection.myWallets)
                    ForEach(session.sharedGroups) { group in
                        Label {
                            Text(group.name)
                        } icon: {
                            SharedGroupMark(size: 26)
                        }
                        .badge(session.entries.filter { $0.groupID == group.id }.count)
                        .tag(Selection.group(group.id))
                        .contextMenu { sharedGroupMenu(group) }
                    }
                }
            }

            if !orderedChains.isEmpty {
                Section("Chains") {
                    ForEach(orderedChains, id: \.self) { chain in
                        Label {
                            Text(chain.displayName)
                        } icon: {
                            ChainLogo(chain: chain, size: 26)
                        }
                        .badge(session.entries.filter { $0.chain == chain }.count)
                        .tag(Selection.chain(chain))
                    }
                }
            }

            if !session.groups.isEmpty {
                Section("Groups") {
                    ForEach(session.groups) { group in
                        Label {
                            Text(group.name)
                        } icon: {
                            GroupMark(group: group, size: 26)
                        }
                        .badge(session.entries.filter { $0.groupID == group.id }.count)
                        .tag(Selection.group(group.id))
                        .contextMenu {
                            Button {
                                renameText = group.name
                                renamingGroup = group
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingGroup = group
                            } label: {
                                Label("Delete Group", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("SafeKey")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button { showingNewGroup = true } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                addMenu
            }
        }
    }

    /// New wallet or new shared group, under one plus — where the Passwords
    /// app keeps both.
    private var addMenu: some View {
        Menu {
            Button { showingAdd = true } label: {
                Label("New Wallet", systemImage: "key.fill")
            }
            Button { showingNewSharedGroup = true } label: {
                Label("New Shared Group", systemImage: "person.2.fill")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .accessibilityIdentifier("home.add")
    }

    @ViewBuilder
    private func sharedGroupMenu(_ group: WalletGroup) -> some View {
        Button {
            managingGroup = group
        } label: {
            Label("Manage", systemImage: "person.2")
        }
        if session.membership(for: group.id)?.isOwner == true {
            Button(role: .destructive) {
                deletingGroup = group
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                leavingGroup = group
            } label: {
                Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        NavigationStack(path: $detailPath) {
            Group {
                if let selection, let filter = filter(for: selection) {
                    EntryListView(session: session, filter: filter, title: title(for: selection))
                } else {
                    ContentUnavailableView {
                        Label("Select a Category", systemImage: "sidebar.left")
                    } description: {
                        Text("Choose a category, chain, or group to see its wallets.")
                    }
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .list(let filter):
                    EntryListView(session: session, filter: filter, title: filter.title(in: session))
                case .entry(let id):
                    EntryDetailView(session: session, entryID: id)
                }
            }
        }
    }

    // MARK: - Mapping

    private struct TileInfo {
        let title: String
        let icon: String
        let tint: Color
        let count: Int
    }

    private func tileInfo(_ tile: VaultSettings.HomeTile) -> TileInfo {
        switch tile {
        case .all:
            TileInfo(title: "All", icon: "key.fill", tint: .blue, count: session.entries.count)
        case .favorites:
            TileInfo(title: "Favorites", icon: "star.fill", tint: .yellow,
                     count: session.entries.filter(\.favorite).count)
        case .seedPhrases:
            TileInfo(title: "Seed Phrases", icon: "text.word.spacing", tint: .purple,
                     count: session.entries.filter { $0.kind.isSeedPhrase }.count)
        case .privateKeys:
            TileInfo(title: "Private Keys", icon: "key.horizontal.fill", tint: .green,
                     count: session.entries.filter { !$0.kind.isSeedPhrase }.count)
        }
    }

    private func filter(for selection: Selection) -> EntryFilter? {
        switch selection {
        case .tile(.all): .all
        case .tile(.favorites): .favorites
        case .tile(.seedPhrases): .seedPhrases
        case .tile(.privateKeys): .privateKeys
        case .chain(let chain): .chain(chain)
        case .group(let id): session.group(id: id) == nil ? nil : .group(id)
        case .myWallets: .ownWallets
        }
    }

    private func title(for selection: Selection) -> String {
        switch selection {
        case .tile(let tile): tileInfo(tile).title
        case .chain(let chain): chain.displayName
        case .group(let id): session.group(id: id)?.name ?? ""
        case .myWallets: "My Wallets"
        }
    }

    // MARK: - Group management

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })
    }

    private func commitRename() {
        guard var group = renamingGroup else { return }
        renamingGroup = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        group.name = name
        session.updateGroup(group)
    }
}
