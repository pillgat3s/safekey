import SwiftUI
import SafeKeyCore

struct SidebarView: View {
    let session: VaultSession
    @Binding var selection: SidebarItem

    @State private var groupBeingRenamed: WalletGroup?
    /// Non-nil while the new-group sheet is up, carrying the chain it is for.
    @State private var newGroupChain: Chain?

    private func count(_ item: SidebarItem) -> Int {
        session.entries.filter { item.matches($0) }.count
    }

    var body: some View {
        List(selection: listSelection) {
            Section {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    CategoryTileView(
                        icon: "key.fill",
                        color: .blue,
                        title: "All",
                        count: count(.all),
                        isSelected: selection == .all
                    ) { selection = .all }
                    CategoryTileView(
                        icon: "star.fill",
                        color: .yellow,
                        title: "Favorites",
                        count: count(.favorites),
                        isSelected: selection == .favorites
                    ) { selection = .favorites }
                    CategoryTileView(
                        icon: "text.word.spacing",
                        color: .purple,
                        title: "Seed Phrases",
                        count: count(.seedPhrases),
                        isSelected: selection == .seedPhrases
                    ) { selection = .seedPhrases }
                    CategoryTileView(
                        icon: "key.horizontal.fill",
                        color: .green,
                        title: "Private Keys",
                        count: count(.privateKeys),
                        isSelected: selection == .privateKeys
                    ) { selection = .privateKeys }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !session.usedChains.isEmpty {
                Section("Chains") {
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
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(group.colorHex.map { Color(hex: $0) } ?? .accentColor)
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
                }
            }

            if !session.allTags.isEmpty {
                Section("Tags") {
                    ForEach(session.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag.fill")
                            .badge(count(.tag(tag)))
                            .tag(SidebarItem.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(DisguiseManager.shared.effectiveName)
        .safeAreaInset(edge: .bottom) {
            Button {
                // Default to whatever chain the sidebar is currently focused on.
                newGroupChain = selection.chainContext(in: session)
                    ?? session.usedChains.first
                    ?? session.settings.defaultChain
            } label: {
                Label("New Group", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
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
