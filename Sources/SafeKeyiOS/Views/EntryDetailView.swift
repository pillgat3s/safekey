import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

struct EntryDetailView: View {
    let session: VaultSession
    let entryID: WalletEntry.ID

    @State private var revealed = false
    @State private var isEditing = false
    @State private var notice: String?

    private var entry: WalletEntry? { session.entry(id: entryID) }

    var body: some View {
        Group {
            if let entry {
                List {
                    Section {
                        HStack(spacing: 14) {
                            ChainLogo(chain: entry.chain, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).font(.title3.bold())
                                Text("\(entry.chain.displayName) · \(entry.kind.displayName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                session.toggleFavorite(id: entry.id)
                            } label: {
                                Image(systemName: entry.favorite ? "star.fill" : "star")
                                    .foregroundStyle(entry.favorite ? .yellow : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }

                    Section(entry.kind.shortName) {
                        if revealed {
                            if entry.kind.isSeedPhrase {
                                SeedPhraseGrid(phrase: entry.secret)
                            } else {
                                Text(entry.secret)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(String(repeating: "•", count: 24))
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            toggleReveal(entry)
                        } label: {
                            Label(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye")
                        }

                        Button {
                            copy(entry.secret, label: "Secret copied")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

                    if let address = entry.publicAddress, !address.isEmpty {
                        Section("Public Address") {
                            Text(address)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button {
                                copy(address, label: "Address copied")
                            } label: {
                                Label("Copy Address", systemImage: "doc.on.doc")
                            }
                        }
                    }

                    if !entry.notes.isEmpty {
                        Section("Notes") { Text(entry.notes) }
                    }

                    if let group = session.group(id: entry.groupID) {
                        Section("Group") {
                            LabeledContent(group.name, value: group.chain.displayName)
                        }
                    }

                    if !entry.tags.isEmpty {
                        Section("Tags") {
                            Text(entry.tags.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Text("Modified \(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { isEditing = true }
                    }
                }
                .sheet(isPresented: $isEditing) {
                    EntryEditView(session: session, existing: entry)
                }
                .overlay(alignment: .bottom) {
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.bottom, 20)
                            .transition(.opacity)
                    }
                }
                .onDisappear { revealed = false }
            } else {
                ContentUnavailableView("Wallet Deleted", systemImage: "trash")
            }
        }
    }

    private func toggleReveal(_ entry: WalletEntry) {
        if revealed {
            revealed = false
        } else {
            Task {
                if await session.authorizeReveal() {
                    withAnimation { revealed = true }
                } else {
                    // Without this the button looks broken: a declined or
                    // failed authentication just left the secret hidden.
                    show("Authentication required to reveal")
                }
            }
        }
    }

    private func show(_ message: String) {
        withAnimation { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { notice = nil }
        }
    }

    /// Copies with the system's expiry so the secret does not linger on the
    /// pasteboard, and marks it so it is excluded from Universal Clipboard.
    private func copy(_ value: String, label: String) {
        let seconds = session.settings.clipboardClearSeconds ?? 0
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if seconds > 0 {
            options[.expirationDate] = Date().addingTimeInterval(TimeInterval(seconds))
        }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: options)
        show(label)
    }
}

struct SeedPhraseGrid: View {
    let phrase: String

    private var words: [String] {
        phrase.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}
