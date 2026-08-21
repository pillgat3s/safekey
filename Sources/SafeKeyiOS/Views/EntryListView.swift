import SwiftUI
import SafeKeyCore

/// Which wallets a list shows. Pushed from a tile, a chain, or a group on the
/// home screen rather than being switched in place, so the list always has a
/// title that says what you are looking at.
enum EntryFilter: Hashable {
    case all, favorites, seedPhrases, privateKeys
    case chain(Chain)
    case group(UUID)

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

/// Wallets bucketed by when they were last touched, newest bucket first — the
/// same shape iOS uses for a credential list.
private struct DateBucket: Identifiable {
    let title: String
    let entries: [WalletEntry]
    var id: String { title }

    static func bucket(_ entries: [WalletEntry], calendar: Calendar = .current) -> [DateBucket] {
        let now = Date()
        var today: [WalletEntry] = []
        var thisWeek: [WalletEntry] = []
        var thisMonth: [WalletEntry] = []
        var earlier: [WalletEntry] = []

        for entry in entries {
            let days = calendar.dateComponents([.day], from: entry.modifiedAt, to: now).day ?? 0
            if calendar.isDateInToday(entry.modifiedAt) {
                today.append(entry)
            } else if days < 7 {
                thisWeek.append(entry)
            } else if days < 30 {
                thisMonth.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        return [
            DateBucket(title: "Today", entries: today),
            DateBucket(title: "This Week", entries: thisWeek),
            DateBucket(title: "Previous 30 Days", entries: thisMonth),
            DateBucket(title: "Earlier", entries: earlier),
        ].filter { !$0.entries.isEmpty }
    }
}

struct EntryListView: View {
    let session: VaultSession
    let filter: EntryFilter
    let title: String
    var initialSearch: String = ""

    @State private var searchText = ""
    @State private var entryPendingDeletion: WalletEntry?

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
        Group {
            if filtered.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Here", systemImage: "key.slash")
                    } description: {
                        Text("No wallets match this category yet.")
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List {
                    ForEach(DateBucket.bucket(filtered)) { bucket in
                        Section {
                            ForEach(bucket.entries) { entry in
                                row(for: entry)
                            }
                        } header: {
                            Text(bucket.title)
                                .font(.title3.bold())
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                                .padding(.leading, -4)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Title with the item count beneath it, the way a credential list
            // tells you how much is in the category you opened.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.headline)
                    Text("\(filtered.count) \(filtered.count == 1 ? "Item" : "Items")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search")
        .onAppear { if searchText.isEmpty { searchText = initialSearch } }
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

    private func row(for entry: WalletEntry) -> some View {
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

struct EntryRow: View {
    let entry: WalletEntry
    var groupName: String?

    var body: some View {
        HStack(spacing: 14) {
            ChainLogo(chain: entry.chain, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if entry.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts = [entry.chain.displayName, entry.kind.shortName]
        if let groupName { parts.append(groupName) }
        return parts.joined(separator: " · ")
    }
}
