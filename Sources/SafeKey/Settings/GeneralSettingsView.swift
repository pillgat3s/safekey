import SwiftUI
import SafeKeyCore

struct GeneralSettingsView: View {
    let session: VaultSession

    var body: some View {
        Form {
            Picker("Default chain for new entries", selection: defaultChainBinding) {
                ForEach(Chain.catalog, id: \.self) { chain in
                    Text(chain.displayName).tag(chain)
                }
            }
            Picker("Sort entries by", selection: sortOrderBinding) {
                Text("Date Modified").tag(VaultSettings.SortOrder.dateModified)
                Text("Name").tag(VaultSettings.SortOrder.name)
                Text("Chain").tag(VaultSettings.SortOrder.chain)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var defaultChainBinding: Binding<Chain> {
        Binding(
            get: { session.settings.defaultChain },
            set: { newValue in
                var settings = session.settings
                settings.defaultChain = newValue
                session.updateSettings(settings)
            }
        )
    }

    private var sortOrderBinding: Binding<VaultSettings.SortOrder> {
        Binding(
            get: { session.settings.sortOrder },
            set: { newValue in
                var settings = session.settings
                settings.sortOrder = newValue
                session.updateSettings(settings)
            }
        )
    }
}
