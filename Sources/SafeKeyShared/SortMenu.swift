import SwiftUI
import SafeKeyCore

/// The list's sort control: the field on top, the direction underneath, each
/// with a checkmark on the active choice.
struct SortMenu: View {
    let session: VaultSession

    var body: some View {
        Menu {
            Picker("Sort By", selection: fieldBinding) {
                ForEach(VaultSettings.SortOrder.allCases, id: \.self) { order in
                    Label(order.label, systemImage: order.symbol).tag(order)
                }
            }
            Divider()
            Picker("Direction", selection: directionBinding) {
                Label(descendingLabel, systemImage: "arrow.down").tag(true)
                Label(ascendingLabel, systemImage: "arrow.up").tag(false)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("list.sort")
    }

    /// Dates read as newest/oldest; text reads as A→Z, which is the same
    /// direction described in the words people actually use for it.
    private var descendingLabel: String {
        switch session.settings.sortOrder {
        case .dateModified, .dateCreated: "Newest First"
        case .name, .chain: "Z to A"
        }
    }

    private var ascendingLabel: String {
        switch session.settings.sortOrder {
        case .dateModified, .dateCreated: "Oldest First"
        case .name, .chain: "A to Z"
        }
    }

    private var fieldBinding: Binding<VaultSettings.SortOrder> {
        Binding(
            get: { session.settings.sortOrder },
            set: { newValue in
                var settings = session.settings
                settings.sortOrder = newValue
                // Clearing the direction lets the new field use its natural
                // one, so picking a date does not inherit "A to Z".
                settings.sortDescending = nil
                session.updateSettings(settings)
            }
        )
    }

    private var directionBinding: Binding<Bool> {
        Binding(
            get: { session.settings.effectiveSortDescending },
            set: { newValue in
                var settings = session.settings
                settings.sortDescending = newValue
                session.updateSettings(settings)
            }
        )
    }
}
