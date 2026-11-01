import SwiftUI

/// The mark a shared group carries everywhere it is listed: two people on a
/// tinted disc, the way the Passwords app marks its shared groups. "My
/// Wallets" — everything outside the shared groups — gets one person on grey.
struct SharedGroupMark: View {
    var size: CGFloat = 26
    /// True for the "My Wallets" row rather than a group.
    var own = false

    var body: some View {
        Image(systemName: own ? "person.fill" : "person.2.fill")
            .font(.system(size: size * (own ? 0.5 : 0.46), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background((own ? Color.gray : Color.blue).gradient, in: .circle)
    }
}
