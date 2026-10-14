import Foundation

/// What SafeKey is for, in the words both apps use: on the first-run notice
/// and on the reminder when a wallet is added. One source, so the two never
/// drift apart.
///
/// Deliberately general about where larger amounts belong. No product, no
/// category of product, is ever named.
enum ScopeNotice {
    static let title = "Made for Burner Wallets"

    static let lead = "SafeKey keeps the throwaway and low-value wallets you'd otherwise leave in Notes, screenshots or chats encrypted and in one place. It is not built to hold significant funds."

    struct Point {
        let symbol: String
        let title: String
        let detail: String
    }

    static let points: [Point] = [
        Point(symbol: "arrow.triangle.2.circlepath", title: "Burner and trading wallets",
              detail: "The keys you spin up often and rotate."),
        Point(symbol: "banknote.fill", title: "Small balances",
              detail: "Amounts you'd be fine losing. Not your savings."),
        Point(symbol: "lock.shield.fill", title: "Larger amounts",
              detail: "Belong in dedicated, secure storage — not here."),
    ]

    static let acknowledge = "I Understand"

    /// The one-line version, for the reminder when a wallet is added.
    static let reminder = "SafeKey is for burner wallets and small balances. Keep larger amounts in dedicated, secure storage."
}

enum ScopeReminder {
    /// UserDefaults key for "Don't Show Again" on the add-wallet reminder.
    static let dismissedKey = "scopeReminderDismissed"
}
