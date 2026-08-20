import SwiftUI
import SafeKeyCore

struct EntryListView: View {
    let session: VaultSession
    let sidebarItem: SidebarItem
    /// Search and the add button live here rather than on the split view:
    /// both act on *this* list, and hosting them here keeps them in the same
    /// toolbar section instead of straddling the column divider.
    @Binding var searchText: String
    @Binding var selectedEntryID: WalletEntry.ID?
    @State private var entryPendingDeletion: WalletEntry?
    @State private var showingAdd = false
    @FocusState private var searchFocused: Bool

    private var filtered: [WalletEntry] {
        var entries = session.entries.filter { sidebarItem.matches($0) }
        if !searchText.isEmpty {
            entries = entries.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.chain.displayName.localizedCaseInsensitiveContains(searchText)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                    || ($0.publicAddress ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        switch session.settings.sortOrder {
        case .dateModified: entries.sort { $0.modifiedAt > $1.modifiedAt }
        case .name: entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .chain: entries.sort { $0.chain.displayName < $1.chain.displayName }
        }
        return entries
    }

    private var buckets: [(String, [WalletEntry])] {
        guard session.settings.sortOrder == .dateModified else {
            return [("", filtered)]
        }
        var grouped: [(String, [WalletEntry])] = []
        for entry in filtered {
            let bucket = DateBucket.label(for: entry.modifiedAt)
            if let last = grouped.indices.last, grouped[last].0 == bucket {
                grouped[last].1.append(entry)
            } else {
                grouped.append((bucket, [entry]))
            }
        }
        return grouped
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                if session.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Wallets Yet", systemImage: "key.fill")
                    } description: {
                        Text("Add your first seed phrase or private key with the + button.")
                    }
                } else if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView {
                        Label("Nothing Here", systemImage: sidebarIcon)
                    } description: {
                        Text("No entries in \(sidebarItem.title(in: session)).")
                    }
                }
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(buckets, id: \.0) { bucket in
                        Section {
                            ForEach(bucket.1) { entry in
                                EntryRowView(entry: entry)
                                    .tag(entry.id)
                                    .contextMenu {
                                        Button(entry.favorite ? "Remove from Favorites" : "Add to Favorites") {
                                            session.toggleFavorite(id: entry.id)
                                        }
                                        if !session.groups.isEmpty {
                                            Menu("Move to Group") {
                                                ForEach(session.groups) { group in
                                                    Button(group.name) {
                                                        session.move(entryID: entry.id, toGroup: group.id)
                                                    }
                                                    .disabled(entry.groupID == group.id)
                                                }
                                                Divider()
                                                Button("Ungrouped") {
                                                    session.move(entryID: entry.id, toGroup: nil)
                                                }
                                                .disabled(entry.groupID == nil)
                                            }
                                        }
                                        Divider()
                                        Button("Delete…", role: .destructive) {
                                            entryPendingDeletion = entry
                                        }
                                    }
                            }
                        } header: {
                            if !bucket.0.isEmpty {
                                Text(bucket.0)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .navigationTitle(sidebarItem.title(in: session))
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Wallet")
                .accessibilityLabel("Add Wallet")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .background {
            // ⌘F focuses search without occupying a visible toolbar slot.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $showingAdd) {
            EntryEditView(session: session, existing: nil)
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
                if let entry = entryPendingDeletion {
                    if selectedEntryID == entry.id { selectedEntryID = nil }
                    session.delete(id: entry.id)
                }
                entryPendingDeletion = nil
            }
        } message: {
            Text("The secret is removed from the encrypted vault. This cannot be undone.")
        }
    }

    private var sidebarIcon: String {
        switch sidebarItem {
        case .favorites: "star"
        case .seedPhrases: "text.word.spacing"
        case .privateKeys: "key.horizontal"
        default: "key"
        }
    }
}

enum DateBucket {
    static func label(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
            return "This Week"
        }
        if let monthAgo = calendar.date(byAdding: .day, value: -30, to: now), date > monthAgo {
            return "Previous 30 Days"
        }
        return String(calendar.component(.year, from: date))
    }
}
