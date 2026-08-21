import SwiftUI
import SafeKeyCore

struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let session: VaultSession

    @State private var sidebarSelection: SidebarItem = .all
    @State private var selectedEntryID: WalletEntry.ID?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
        } content: {
            EntryListView(
                session: session,
                sidebarItem: sidebarSelection,
                searchText: $searchText,
                selectedEntryID: $selectedEntryID
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            if let id = selectedEntryID, let entry = session.entry(id: id) {
                EntryDetailView(session: session, entry: entry)
            } else {
                EmptyDetailView()
            }
        }
        .alert(
            "Save Failed",
            isPresented: Binding(
                get: { session.saveError != nil },
                set: { if !$0 { session.saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.saveError ?? "")
        }
        // Coming back to the app is the moment to pick up what the phone did.
        // A Mac can sit unlocked all day, so syncing only at unlock would mean
        // never pulling at all.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.sync.syncIfEnabled(session: session) }
        }
    }
}
