import SwiftUI
import SafeKeyCore

/// Masked secret row with reveal + copy, Passwords-style. The clipboard copy
/// goes through `ClipboardGuard` so it is auto-cleared and marked concealed.
struct SecretRevealRow: View {
    let entry: WalletEntry
    let session: VaultSession
    @State private var revealed = false

    var body: some View {
        content
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: PromoDirector.command)) { note in
                switch note.object as? PromoDirector.Command {
                case .reveal?: withAnimation(.easeOut(duration: 0.15)) { revealed = true }
                case .hide?: withAnimation(.easeOut(duration: 0.15)) { revealed = false }
                default: break
                }
            }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.kind.shortName)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if revealed {
                        withAnimation(.easeOut(duration: 0.15)) { revealed = false }
                    } else {
                        Task {
                            if await session.authorizeReveal() {
                                withAnimation(.easeOut(duration: 0.15)) { revealed = true }
                            }
                        }
                    }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide" : "Reveal")
                .accessibilityLabel(revealed ? "Hide secret" : "Reveal secret")
                Button {
                    ClipboardGuard.shared.copy(entry.secret, clearAfter: session.settings.clipboardClearSeconds)
                } label: {
                    Image(systemName: "document.on.document")
                }
                .buttonStyle(.borderless)
                .help("Copy (auto-clears from clipboard)")
                .accessibilityLabel("Copy secret")
            }

            if revealed {
                if entry.kind.isSeedPhrase {
                    SeedPhraseGridView(phrase: entry.secret)
                } else {
                    Text(entry.secret)
                        .font(.callout.monospaced())
                        // A key is not a word: typeset it as having no
                        // language, or a wrapped line gains a hyphen that is
                        // not part of the key.
                        .typesettingLanguage(.init(identifier: "zxx"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(String(repeating: "•", count: 24))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: entry.id) {
            revealed = false
        }
    }
}
