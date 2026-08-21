import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

/// Reorders the sidebar tiles as the drag moves over them, matching the grid
/// on the iPhone.
private struct SidebarTileDropDelegate: DropDelegate {
    let target: VaultSettings.HomeTile
    @Binding var dragging: VaultSettings.HomeTile?
    let move: (VaultSettings.HomeTile, VaultSettings.HomeTile) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.25)) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct SidebarView: View {
    let session: VaultSession
    @Binding var selection: SidebarItem

    @State private var groupBeingRenamed: WalletGroup?
    /// Non-nil while the new-group sheet is up, carrying the chain it is for.
    @State private var newGroupChain: Chain?

    private func count(_ item: SidebarItem) -> Int {
        session.entries.filter { item.matches($0) }.count
    }

    @State private var draggingTile: VaultSettings.HomeTile?
    // Device-local: which sections are folded is not vault data.
    @AppStorage("sidebar.chainsExpanded") private var chainsExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = true

    private var visibleTiles: [VaultSettings.HomeTile] {
        let settings = session.settings
        return VaultSettings.ordered(VaultSettings.HomeTile.allCases, by: settings.homeTileOrder)
            .filter { !settings.hiddenHomeTiles.contains($0) }
    }

    private func item(for tile: VaultSettings.HomeTile) -> SidebarItem {
        switch tile {
        case .all: .all
        case .favorites: .favorites
        case .seedPhrases: .seedPhrases
        case .privateKeys: .privateKeys
        }
    }

    private func title(for tile: VaultSettings.HomeTile) -> String {
        switch tile {
        case .all: "All"
        case .favorites: "Favorites"
        case .seedPhrases: "Seed Phrases"
        case .privateKeys: "Private Keys"
        }
    }

    private func icon(for tile: VaultSettings.HomeTile) -> String {
        switch tile {
        case .all: "key.fill"
        case .favorites: "star.fill"
        case .seedPhrases: "text.word.spacing"
        case .privateKeys: "key.horizontal.fill"
        }
    }

    private func tint(for tile: VaultSettings.HomeTile) -> Color {
        switch tile {
        case .all: .blue
        case .favorites: .yellow
        case .seedPhrases: .purple
        case .privateKeys: .green
        }
    }

    /// Reorders across the full set, not just the visible ones, so a hidden
    /// tile keeps its place for when it is shown again.
    private func moveTile(_ tile: VaultSettings.HomeTile, before target: VaultSettings.HomeTile) {
        guard tile != target else { return }
        var order = VaultSettings.ordered(VaultSettings.HomeTile.allCases, by: session.settings.homeTileOrder)
        guard let from = order.firstIndex(of: tile) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(tile, at: to)
        var settings = session.settings
        settings.homeTileOrder = order
        session.updateSettings(settings)
    }

    private func hideTile(_ tile: VaultSettings.HomeTile) {
        guard visibleTiles.count > 1 else { return }
        var settings = session.settings
        guard !settings.hiddenHomeTiles.contains(tile) else { return }
        settings.hiddenHomeTiles.append(tile)
        if selection == item(for: tile) { selection = .all }
        session.updateSettings(settings)
    }

    private func showAllTiles() {
        var settings = session.settings
        settings.hiddenHomeTiles = []
        session.updateSettings(settings)
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    // Order and visibility come from the vault, so the layout
                    // matches whatever was arranged on the iPhone.
                    ForEach(visibleTiles, id: \.self) { tile in
                        CategoryTileView(
                            icon: icon(for: tile),
                            color: tint(for: tile),
                            title: title(for: tile),
                            count: count(item(for: tile)),
                            isSelected: selection == item(for: tile)
                        ) { selection = item(for: tile) }
                        .onDrag {
                            draggingTile = tile
                            return NSItemProvider(object: tile.rawValue as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: SidebarTileDropDelegate(
                                target: tile,
                                dragging: $draggingTile,
                                move: moveTile
                            )
                        )
                        .contextMenu {
                            if visibleTiles.count > 1 {
                                Button("Hide \(title(for: tile))") { hideTile(tile) }
                            }
                            if !session.settings.hiddenHomeTiles.isEmpty {
                                Button("Show Hidden Categories") { showAllTiles() }
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !session.usedChains.isEmpty {
                Section(isExpanded: $chainsExpanded) {
                    // Groups live under the chain they organise, indented, so
                    // the hierarchy matches how the wallets are actually
                    // thought about: a network, then folders inside it.
                    ForEach(session.usedChains, id: \.self) { chain in
                        Label {
                            Text(chain.displayName)
                        } icon: {
                            ChainLogo(chain: chain, size: 18)
                        }
                        .badge(count(.chain(chain)))
                        .tag(SidebarItem.chain(chain))
                        .contextMenu {
                            Button("New Group in \(chain.displayName)…") {
                                newGroupChain = chain
                            }
                        }

                        ForEach(session.groups(for: chain)) { group in
                            Label {
                                Text(group.name)
                            } icon: {
                                GroupMark(group: group, size: 18)
                            }
                            .badge(count(.group(group.id)))
                            .tag(SidebarItem.group(group.id))
                            .padding(.leading, 16)
                            .contextMenu {
                                Button("Rename…") { groupBeingRenamed = group }
                                Button("Delete Group", role: .destructive) {
                                    if selection == .group(group.id) { selection = .chain(chain) }
                                    session.deleteGroup(id: group.id)
                                }
                            }
                        }

                        if session.hasUngroupedEntries(in: chain) {
                            Label("Ungrouped", systemImage: "tray")
                                .badge(count(.ungrouped(chain)))
                                .tag(SidebarItem.ungrouped(chain))
                                .padding(.leading, 16)
                        }
                    }
                } header: {
                    Text("Chains")
                }
            }

            if !session.allTags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(session.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag.fill")
                            .badge(count(.tag(tag)))
                            .tag(SidebarItem.tag(tag))
                    }
                } header: {
                    Text("Tags")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(DisguiseManager.shared.effectiveName)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button {
                    // Default to whatever chain the sidebar is currently focused on.
                    newGroupChain = selection.chainContext(in: session)
                        ?? session.usedChains.first
                        ?? session.settings.defaultChain
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("New group")

                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .sheet(item: $newGroupChain) { chain in
            GroupEditorView(session: session, chain: chain, existing: nil)
        }
        .sheet(item: $groupBeingRenamed) { group in
            GroupEditorView(session: session, chain: group.chain, existing: group)
        }
    }

    /// The grid tiles set `selection` directly; the List rows (chains/tags)
    /// participate via tags through this optional-bridging binding.
    private var listSelection: Binding<SidebarItem?> {
        Binding(
            get: { selection },
            set: { if let newValue = $0 { selection = newValue } }
        )
    }
}
