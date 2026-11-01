import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

/// Reorders the grid as the drag moves, rather than only on release: entering a
/// tile's bounds moves the dragged tile into that position and the rest animate
/// aside, which is how the Home Screen behaves.
private struct TileDropDelegate: DropDelegate {
    let target: VaultSettings.HomeTile
    @Binding var dragging: VaultSettings.HomeTile?
    let move: (VaultSettings.HomeTile, VaultSettings.HomeTile) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.25)) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Home screen, laid out the way iOS presents a credential vault: a grid of
/// category tiles over sections for the ways this vault is organised, with
/// search and adding on the bottom bar and settings top-right.
struct VaultHomeView: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingNewGroup = false
    @State private var showingNewSharedGroup = false
    @State private var managingGroup: WalletGroup?
    @State private var dragging: VaultSettings.HomeTile?
    @State private var renamingGroup: WalletGroup?
    @State private var renameText = ""
    @State private var deletingGroup: WalletGroup?
    @State private var leavingGroup: WalletGroup?
    // Device-local view state rather than vault data: which sections you have
    // folded away is not worth carrying inside an encrypted backup.
    @AppStorage("home.chainsExpanded") private var chainsExpanded = true
    @AppStorage("home.groupsExpanded") private var groupsExpanded = true
    /// The navigation stack as values, written to the model on every step so
    /// the next session can rebuild it after a lock.
    @State private var path: [HomeRoute]

    init(session: VaultSession, resume: [HomeRoute] = []) {
        self.session = session
        _path = State(initialValue: resume)
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    /// Built in the user's order, minus anything they hid.
    private var categories: [Category] {
        let settings = session.settings
        let visible = VaultSettings.ordered(VaultSettings.HomeTile.allCases, by: settings.homeTileOrder)
            .filter { !settings.hiddenHomeTiles.contains($0) }
        return visible.map { tile in
            switch tile {
            case .all:
                Category(tile: .all, filter: .all, title: "All", icon: "key.fill", tint: .blue,
                         count: session.entries.count)
            case .favorites:
                Category(tile: .favorites, filter: .favorites, title: "Favorites", icon: "star.fill", tint: .yellow,
                         count: session.entries.filter(\.favorite).count)
            case .seedPhrases:
                Category(tile: .seedPhrases, filter: .seedPhrases, title: "Seed Phrases", icon: "text.word.spacing", tint: .purple,
                         count: session.entries.filter { $0.kind.isSeedPhrase }.count)
            case .privateKeys:
                Category(tile: .privateKeys, filter: .privateKeys, title: "Private Keys", icon: "key.horizontal.fill", tint: .green,
                         count: session.entries.filter { !$0.kind.isSeedPhrase }.count)
            }
        }
    }

    // MARK: - Groups

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

    // MARK: - Rearranging

    private var visibleTiles: [VaultSettings.HomeTile] {
        let settings = session.settings
        return VaultSettings.ordered(VaultSettings.HomeTile.allCases, by: settings.homeTileOrder)
            .filter { !settings.hiddenHomeTiles.contains($0) }
    }

    private func move(_ tile: VaultSettings.HomeTile, before target: VaultSettings.HomeTile) {
        guard tile != target else { return }
        // Reorder the full set, not just the visible ones, so a hidden tile
        // keeps its place when it is shown again.
        var order = VaultSettings.ordered(VaultSettings.HomeTile.allCases, by: session.settings.homeTileOrder)
        guard let from = order.firstIndex(of: tile), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(tile, at: order.firstIndex(of: target) ?? to)
        var settings = session.settings
        settings.homeTileOrder = order
        session.updateSettings(settings)
    }

    /// False when only one category is left showing.
    private var canHideMore: Bool { visibleTiles.count > 1 }

    private func hide(_ tile: VaultSettings.HomeTile) {
        guard canHideMore else { return }
        var settings = session.settings
        guard !settings.hiddenHomeTiles.contains(tile) else { return }
        settings.hiddenHomeTiles.append(tile)
        session.updateSettings(settings)
    }

    private func showAllTiles() {
        var settings = session.settings
        settings.hiddenHomeTiles = []
        session.updateSettings(settings)
    }

    private var orderedChains: [Chain] {
        VaultSettings.ordered(session.usedChains, by: session.settings.chainOrder)
    }

    /// Every group in the vault, so a disappearing one is noticed.
    private var groupIDs: Set<UUID> {
        Set(session.unlocked.payload.groups.map(\.id))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if !searchText.isEmpty {
                    searchResults
                } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(categories) { category in
                        NavigationLink(value: HomeRoute.list(category.filter)) {
                            CategoryTile(category: category)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tile.\(category.title)")
                        // Long-press to hide, or drag to reorder — where iOS
                        // puts rearranging, rather than in a settings screen.
                        .onDrag {
                            dragging = category.tile
                            return NSItemProvider(object: category.tile.rawValue as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TileDropDelegate(
                                target: category.tile,
                                dragging: $dragging,
                                move: { moved, target in move(moved, before: target) }
                            )
                        )
                        .contextMenu {
                            if canHideMore {
                                Button {
                                    hide(category.tile)
                                } label: {
                                    Label("Hide \(category.title)", systemImage: "eye.slash")
                                }
                            }
                            if !session.settings.hiddenHomeTiles.isEmpty {
                                Button {
                                    showAllTiles()
                                } label: {
                                    Label("Show Hidden Categories", systemImage: "eye")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                // Shared groups sit right under the tiles, with "My Wallets"
                // for everything that is not shared — the arrangement the
                // Passwords app uses once there is a shared group.
                if !session.sharedGroups.isEmpty {
                    sectionHeader("Shared Groups")
                    VStack(spacing: 0) {
                        NavigationLink(value: HomeRoute.list(.ownWallets)) {
                            RowLabel(title: "My Wallets", count: session.ownEntries.count) {
                                SharedGroupMark(size: 26, own: true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.myWallets")
                        rowDivider
                        ForEach(Array(session.sharedGroups.enumerated()), id: \.element) { index, group in
                            NavigationLink(value: HomeRoute.list(.group(group.id))) {
                                RowLabel(
                                    title: group.name,
                                    subtitle: session.membership(for: group.id)?.isOwner == true ? "Owner" : "Shared with you",
                                    count: session.entries.filter { $0.groupID == group.id }.count
                                ) {
                                    SharedGroupMark(size: 26)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.sharedGroup.\(group.name)")
                            .contextMenu {
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
                            if index < session.sharedGroups.count - 1 { rowDivider }
                        }
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                }

                if !orderedChains.isEmpty {
                    collapsibleHeader("Chains", isExpanded: $chainsExpanded)
                    if chainsExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(orderedChains.enumerated()), id: \.element) { index, chain in
                            NavigationLink(value: HomeRoute.list(.chain(chain))) {
                                RowLabel(
                                    title: chain.displayName,
                                    count: session.entries.filter { $0.chain == chain }.count
                                ) {
                                    ChainLogo(chain: chain, size: 26)
                                }
                            }
                            .buttonStyle(.plain)
                            if index < orderedChains.count - 1 { rowDivider }
                        }
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if !session.groups.isEmpty {
                    collapsibleHeader("Groups", isExpanded: $groupsExpanded)
                    if groupsExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(session.groups.enumerated()), id: \.element) { index, group in
                            NavigationLink(value: HomeRoute.list(.group(group.id))) {
                                RowLabel(
                                    title: group.name,
                                    subtitle: group.chain.displayName,
                                    count: session.entries.filter { $0.groupID == group.id }.count
                                ) {
                                    GroupMark(group: group, size: 26)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.group.\(group.name)")
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
                            if index < session.groups.count - 1 { rowDivider }
                        }
                    }
                    .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if session.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Wallets Yet", systemImage: "key.fill")
                    } description: {
                        Text("Tap + to store your first recovery phrase or private key.")
                    }
                    .padding(.top, 40)
                }
                }
            }
            .navigationTitle("SafeKey")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .list(let filter):
                    EntryListView(session: session, filter: filter, title: filter.title(in: session))
                case .entry(let id):
                    EntryDetailView(session: session, entryID: id)
                }
            }
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                // New group, where iOS puts the same action in a credential
                // vault. Locking moved into Settings; the vault also locks
                // itself whenever the app leaves the foreground.
                ToolbarItem(placement: .bottomBar) {
                    Button { showingNewGroup = true } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                }
                // The system search field sits between the two buttons and
                // takes whatever width is left, so it grows with the phone: a
                // Pro Max gets the same edge-to-edge bar as the Passwords app
                // rather than a short field inside wide margins. The spacers
                // keep the three pieces floating separately.
                ToolbarSpacer(.fixed, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                // New wallet or new shared group, under one plus — where the
                // Passwords app keeps both.
                ToolbarItem(placement: .bottomBar) {
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
            }
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
            .modifier(BiometricOffer(
                session: session,
                sheetsPresented: showingSettings || showingAdd || showingNewGroup || showingNewSharedGroup || managingGroup != nil
            ))
            .onChange(of: path) { _, current in model.resume.noteHome(current) }
            // A group can go while its list is up — deleted or left from its
            // own Manage screen, or taken away by a sync. The list behind the
            // sheet would otherwise sit there showing nothing.
            .onChange(of: groupIDs) { _, _ in
                let valid = path.validated(in: session)
                if valid.count != path.count { path = valid }
            }
            .onAppear { UnlockTrace.mark("home-appeared") }
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
                    if let group = deletingGroup { session.deleteGroup(id: group.id) }
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
                    if let group = leavingGroup { session.leaveSharedGroup(id: group.id) }
                    leavingGroup = nil
                }
            } message: {
                Text("The group's wallets are removed from this device. You will need a new invitation to rejoin.")
            }
        }
    }

    /// Results replace the grid in place while searching, rather than pushing a
    /// second screen that would have to be kept in step with the list.
    private var matches: [WalletEntry] {
        session.entries
            .filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.chain.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                    || ($0.publicAddress ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @ViewBuilder
    private var searchResults: some View {
        if matches.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                    NavigationLink(value: HomeRoute.entry(entry.id)) {
                        HStack {
                            EntryRow(entry: entry, groupName: session.group(id: entry.groupID)?.name)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < matches.count - 1 { Divider().padding(.leading, 78) }
                }
            }
            .padding(.top, 4)
        }
    }

    /// A section title that does not fold: the shared groups are few and
    /// always worth seeing.
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .accessibilityIdentifier("home.section.\(title)")
    }

    /// Section title with a disclosure chevron beside it.
    private func collapsibleHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .accessibilityIdentifier("home.section.\(title)")
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 52)
    }
}

struct Category: Identifiable {
    let tile: VaultSettings.HomeTile
    let filter: EntryFilter
    let title: String
    let icon: String
    let tint: Color
    let count: Int

    var id: String { title }
}

/// Circular tinted glyph, count top-right, label underneath.
struct CategoryTile: View {
    let category: Category

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: category.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(category.tint.gradient, in: .circle)
                Spacer(minLength: 0)
                Text("\(category.count)")
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(category.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// A chain or group row: leading mark, title, count, chevron.
struct RowLabel<Mark: View>: View {
    let title: String
    var subtitle: String?
    let count: Int
    @ViewBuilder var mark: Mark

    var body: some View {
        HStack(spacing: 12) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
