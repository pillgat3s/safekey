import SwiftUI

struct EmptyDetailView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Wallet Selected", systemImage: "key.fill")
        } description: {
            Text("Select an entry to view its details.")
        }
    }
}
