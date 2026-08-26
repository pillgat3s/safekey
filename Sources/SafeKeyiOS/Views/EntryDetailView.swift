import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

struct EntryDetailView: View {
    let session: VaultSession
    let entryID: WalletEntry.ID

    @State private var revealed = false
    private let capture = ScreenCapture.shared
    @State private var isEditing = false
    @State private var notice: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""

    private var entry: WalletEntry? { session.entry(id: entryID) }

    var body: some View {
        Group {
            if let entry {
                List {
                    // Centred mark and name, then the facts as a grouped card —
                    // the shape iOS uses for a single credential.
                    Section {
                        VStack(spacing: 12) {
                            ChainLogo(chain: entry.chain, size: 88)
                            Text(entry.name)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    // The secret, presented the way the Passwords app presents
                    // a password: a captioned row of dots that reveals in place
                    // when tapped, hides when tapped again, and carries Copy on
                    // a long press. No menu between you and the value.
                    Section {
                        Button {
                            toggleReveal(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.kind.shortName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if revealed, entry.kind.isSeedPhrase {
                                    SeedPhraseGrid(phrase: entry.secret)
                                } else if revealed {
                                    Text(entry.secret)
                                        .font(.callout.monospaced())
                                        .accessibilityIdentifier("detail.secret")
                                } else {
                                    // A fixed run of dots: the mask must not
                                    // leak the secret's length.
                                    Text(String(repeating: "•", count: 8))
                                        .font(.body.monospaced())
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("detail.secretRow")
                        .contextMenu {
                            Button {
                                copy(entry.secret, label: "\(entry.kind.shortName) copied")
                            } label: {
                                Label("Copy \(entry.kind.shortName)", systemImage: "doc.on.doc")
                            }
                            Button {
                                toggleReveal(entry)
                            } label: {
                                Label(revealed ? "Hide" : "Reveal", systemImage: revealed ? "eye.slash" : "eye")
                            }
                        }
                    }

                    Section {
                        if let address = entry.publicAddress, !address.isEmpty {
                            Menu {
                                Button {
                                    copy(address, label: "Address copied")
                                } label: {
                                    Label("Copy Address", systemImage: "doc.on.doc")
                                }
                            } label: {
                                LabeledContent("Address") {
                                    Text(address)
                                        .font(.callout.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }

                        LabeledContent("Chain", value: entry.chain.displayName)

                        // The group is chosen here, the way iOS lets you move a
                        // credential between groups from its own screen.
                        Menu {
                            Picker("Group", selection: groupBinding(for: entry)) {
                                Text("None").tag(UUID?.none)
                                ForEach(session.groups(for: entry.chain)) { group in
                                    Text(group.name).tag(UUID?.some(group.id))
                                }
                            }
                            Divider()
                            Button {
                                newGroupName = ""
                                creatingGroup = true
                            } label: {
                                Label("New Group…", systemImage: "plus.circle")
                            }
                        } label: {
                            LabeledContent("Group") {
                                HStack(spacing: 4) {
                                    Text(session.group(id: entry.groupID)?.name ?? "None")
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                            }
                        }
                        .accessibilityIdentifier("detail.groupRow")

                        if !entry.tags.isEmpty {
                            LabeledContent("Tags", value: entry.tags.joined(separator: ", "))
                        }

                        LabeledContent(
                            "Modified",
                            value: entry.modifiedAt.formatted(date: .abbreviated, time: .omitted)
                        )
                    }

                    if !entry.notes.isEmpty {
                        Section("Notes") { Text(entry.notes) }
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Share offers the public address only. A share sheet is a
                    // route to any app on the phone, and a seed phrase that
                    // leaves through it is unrecoverable — so the secret is
                    // reachable by Copy, which is deliberate and local, and
                    // never by Share.
                    if let address = entry.publicAddress, !address.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: address) {
                                Label("Share Address", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { isEditing = true }
                    }
                }
                .sheet(isPresented: $isEditing) {
                    EntryEditView(session: session, existing: entry)
                }
                .alert("New Group", isPresented: $creatingGroup) {
                    TextField("Group name", text: $newGroupName)
                    Button("Cancel", role: .cancel) { newGroupName = "" }
                    Button("Create") { createGroup(for: entry) }
                } message: {
                    Text("Groups organise wallets within \(entry.chain.displayName).")
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
                // Recording, mirroring, and streaming are the ways a revealed
                // secret leaves the device unnoticed. Re-hide the moment one
                // starts; reveal is also refused while one is running.
                .onChange(of: capture.isCaptured) { _, captured in
                    if captured, revealed {
                        revealed = false
                        show("Hidden — the screen is being recorded or mirrored")
                    }
                }
            } else {
                ContentUnavailableView("Wallet Deleted", systemImage: "trash")
            }
        }
    }

    private func groupBinding(for entry: WalletEntry) -> Binding<UUID?> {
        Binding(
            get: { entry.groupID },
            set: { session.move(entryID: entry.id, toGroup: $0) }
        )
    }

    private func createGroup(for entry: WalletEntry) {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        newGroupName = ""
        guard !name.isEmpty else { return }
        let group = session.addGroup(name: name, chain: entry.chain, colorHex: nil)
        session.move(entryID: entry.id, toGroup: group.id)
    }

    private func toggleReveal(_ entry: WalletEntry) {
        if revealed {
            revealed = false
        } else if capture.isCaptured {
            show("Unavailable while the screen is recorded or mirrored")
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
