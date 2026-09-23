import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

struct EntryDetailView: View {
    let session: VaultSession
    let entryID: WalletEntry.ID
    @Environment(AppModel.self) private var model

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
                                .onAppear { UnlockTrace.mark("detail-appeared") }
                            Text(entry.name)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    // One card for everything, the way the Passwords app lays
                    // out a credential: address first — it is what gets copied
                    // and shared — then the secret, then the bookkeeping. Every
                    // row is a label on the left and a value on the right.
                    Section {
                        if let address = entry.publicAddress, !address.isEmpty {
                            Button {
                                copy(address, label: "Address copied")
                            } label: {
                                row("Address") {
                                    Text(address)
                                        .font(.callout.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .accessibilityIdentifier("detail.addressRow")
                        }

                        // The secret: a row of dots that reveals in place when
                        // tapped and hides when tapped again, with its own Copy
                        // button so copying never needs the value on screen.
                        // Deliberately no long-press menu: iOS 27 appends an
                        // "Ask Siri" item to every context menu, and a private
                        // key must never sit one tap from leaving the device
                        // that way. A key or a phrase is too long for the
                        // right-hand side, so a revealed value drops under its
                        // label.
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Button {
                                toggleReveal(entry)
                            } label: {
                                if revealed {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(entry.kind.shortName)
                                            .foregroundStyle(Color.primary)
                                        // On the secure layer: visible to the
                                        // eye, blank in a screenshot or a
                                        // recording, as the Passwords app does
                                        // for a password.
                                        ScreenshotHidden {
                                            if entry.kind.isSeedPhrase {
                                                SeedPhraseGrid(phrase: entry.secret)
                                            } else {
                                                Text(entry.secret)
                                                    .font(.callout.monospaced())
                                                    .foregroundStyle(Color.secondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .accessibilityIdentifier("detail.secret")
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                } else {
                                    row(entry.kind.shortName) {
                                        // A fixed run of dots: the mask must not
                                        // leak the secret's length.
                                        Text(String(repeating: "•", count: 8))
                                            .font(.body.monospaced())
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("detail.secretRow")

                            Button {
                                copy(entry.secret, label: "\(entry.kind.shortName) copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.callout)
                                    .foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy \(entry.kind.shortName)")
                            .accessibilityIdentifier("detail.copySecret")
                        }

                        row("Chain") { Text(entry.chain.displayName) }

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
                            row("Group") {
                                HStack(spacing: 4) {
                                    Text(session.group(id: entry.groupID)?.name ?? "None")
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                            }
                        }
                        .accessibilityIdentifier("detail.groupRow")

                        if !entry.tags.isEmpty {
                            row("Tags") { Text(entry.tags.joined(separator: ", ")) }
                        }

                        row("Modified") {
                            Text(entry.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                        }

                        if !entry.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Notes")
                                Text(entry.notes).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Share offers the public address only. A share sheet is a
                    // route to any app on the phone, and a seed phrase that
                    // leaves through it is unrecoverable — so the secret is
                    // reachable by Copy, which is deliberate and local, and
                    // never by Share. The spacer keeps Share and Edit as two
                    // separate pieces, as the Passwords app has them.
                    if let address = entry.publicAddress, !address.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: address) {
                                Label("Share Address", systemImage: "square.and.arrow.up")
                            }
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
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

    /// A label on the left, a value on the right — the row every fact in the
    /// card shares. The colours are the concrete label colours, not the
    /// hierarchical `.primary`/`.secondary` styles: those are relative to the
    /// current foreground, and inside a `Button` or a `Menu` that is the
    /// accent colour, which turned the whole row blue.
    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Color.primary)
            Spacer(minLength: 12)
            value()
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
                // The prompt makes the scene inactive; the model keeps the
                // privacy cover from treating that as leaving the app.
                if await session.authorizeReveal(onPrompt: { model.noteAuthenticationPrompt() }) {
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
                        // Concrete, not hierarchical: the grid sits inside the
                        // secret row's button, whose foreground is the tint.
                        .foregroundStyle(Color(.tertiaryLabel))
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
