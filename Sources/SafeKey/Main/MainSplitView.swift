import SwiftUI
import SafeKeyCore

struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let session: VaultSession

    @State private var sidebarSelection: SidebarItem = .all
    @State private var selectedEntryID: WalletEntry.ID?
    @State private var searchText = ""
    @State private var offeringTouchID = false

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
        // Asked once when a different vault takes this Mac's place — adopted
        // from iCloud, or restored from a backup — because the Touch ID
        // enrolment was keyed to the vault that left. A vault behind a USB
        // security key is excluded: enabling Touch ID for it needs the key
        // file, and Settings has the flow for that.
        .task(id: session.header.vaultID) {
            guard model.biometricOfferPending,
                  !session.header.unlockPolicy.requiresDevice,
                  BiometricFactor.isBiometryAvailable(),
                  !model.biometricFactor.isEnrolled(vaultID: session.header.vaultID)
            else { return }
            model.clearBiometricOffer()
            offeringTouchID = true
        }
        .alert("Unlock with Touch ID?", isPresented: $offeringTouchID) {
            Button("Not Now", role: .cancel) {}
            Button("Use Touch ID") {
                Task { try? await model.enableBiometricUnlock() }
            }
        } message: {
            Text("This vault came from another device. You can open it on this Mac with Touch ID instead of typing its master password.")
        }
        // Coming back to the app is the moment to pick up what the phone did.
        // A Mac can sit unlocked all day, so syncing only at unlock would mean
        // never pulling at all.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.sync.syncIfEnabled(session: session) }
        }
    }
}
