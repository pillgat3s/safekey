import SwiftUI
import SafeKeyCore

/// Main list. A phone has no three-pane layout, so the Mac sidebar's chains and
/// groups become a filter menu plus sections instead.
struct VaultListView: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model

    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var entryPendingDeletion: WalletEntry?

    enum Filter: Hashable {
        case all, favorites, seedPhrases, privateKeys
        case chain(Chain)
        case group(UUID)

        /// A group's name lives in the vault, so the title needs the session —
        /// and the session is main-actor isolated, as is every caller here.
        @MainActor
        func title(in session: VaultSession) -> String {
            switch self {
            case .all: "All Wallets"
            case .favorites: "Favorites"
            case .seedPhrases: "Seed Phrases"
            case .privateKeys: "Private Keys"
            case .chain(let chain): chain.displayName
            case .group(let id): session.group(id: id)?.name ?? "Group"
            }
        }

        func matches(_ entry: WalletEntry) -> Bool {
            switch self {
            case .all: true
            case .favorites: entry.favorite
            case .seedPhrases: entry.kind.isSeedPhrase
            case .privateKeys: !entry.kind.isSeedPhrase
            case .chain(let chain): entry.chain == chain
            case .group(let id): entry.groupID == id
            }
        }
    }

    private var filtered: [WalletEntry] {
        var entries = session.entries.filter { filter.matches($0) }
        if !searchText.isEmpty {
            entries = entries.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.chain.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                    || ($0.publicAddress ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        return entries.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Wallets Yet", systemImage: "key.fill")
                    } description: {
                        Text("Tap + to store your first recovery phrase or private key.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filtered) { entry in
                            NavigationLink {
                                EntryDetailView(session: session, entryID: entry.id)
                            } label: {
                                EntryRow(entry: entry, groupName: session.group(id: entry.groupID)?.name)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    entryPendingDeletion = entry
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    session.toggleFavorite(id: entry.id)
                                } label: {
                                    Label("Favorite", systemImage: entry.favorite ? "star.slash" : "star")
                                }
                                .tint(.yellow)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(filter.title(in: session))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search wallets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            Label("All Wallets", systemImage: "key.fill").tag(Filter.all)
                            Label("Favorites", systemImage: "star").tag(Filter.favorites)
                            Label("Seed Phrases", systemImage: "text.word.spacing").tag(Filter.seedPhrases)
                            Label("Private Keys", systemImage: "key.horizontal").tag(Filter.privateKeys)
                            ForEach(session.usedChains, id: \.self) { chain in
                                Text(chain.displayName).tag(Filter.chain(chain))
                            }
                            ForEach(session.groups) { group in
                                Text("\(group.chain.displayName) › \(group.name)").tag(Filter.group(group.id))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Label("Add Wallet", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button { model.lock() } label: {
                            Label("Lock", systemImage: "lock.fill")
                        }
                        Spacer()
                        Button { showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                EntryEditView(session: session, existing: nil)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(session: session)
            }
            .confirmationDialog(
                "Delete “\(entryPendingDeletion?.name ?? "")”?",
                isPresented: Binding(
                    get: { entryPendingDeletion != nil },
                    set: { if !$0 { entryPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let entry = entryPendingDeletion { session.delete(id: entry.id) }
                    entryPendingDeletion = nil
                }
            } message: {
                Text("This removes the secret from the vault permanently.")
            }
        }
    }
}

struct EntryRow: View {
    let entry: WalletEntry
    var groupName: String?

    var body: some View {
        HStack(spacing: 12) {
            ChainLogo(chain: entry.chain, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name).lineLimit(1)
                    if entry.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [entry.chain.displayName, entry.kind.shortName]
        if let groupName { parts.append(groupName) }
        return parts.joined(separator: " · ")
    }
}
