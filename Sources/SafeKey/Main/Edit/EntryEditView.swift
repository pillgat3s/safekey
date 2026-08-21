import SwiftUI
import SafeKeyCore

/// Add/edit sheet. `existing == nil` means a new entry.
struct EntryEditView: View {
    let session: VaultSession
    var existing: WalletEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chain: Chain = .evm
    @State private var showingChainPicker = false
    @State private var kindSelection: KindSelection = .seedPhrase
    @State private var secret = ""
    @State private var publicAddress = ""
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var favorite = false
    @State private var groupID: UUID?
    @State private var showingDerivation = false

    /// Only Solana is implemented so far, and only when there is a secret to
    /// work from.
    private var canDeriveAddress: Bool {
        chain == .solana && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enteredTags: [String] {
        tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Existing tags not already on this entry, most-used first.
    private var tagSuggestions: [String] {
        let used = Set(enteredTags.map { $0.lowercased() })
        return session.tagsByFrequency.filter { !used.contains($0.lowercased()) }.prefix(12).map { $0 }
    }

    private func appendTag(_ tag: String) {
        var tags = enteredTags
        tags.append(tag)
        tagsText = tags.joined(separator: ", ")
    }

    /// One seed-phrase option rather than a 12- and a 24-word one: the length
    /// is a property of what was pasted, not a choice to make beforehand, and
    /// offering both invited picking the wrong one.
    enum KindSelection: String, CaseIterable, Identifiable {
        case seedPhrase, privateKey
        var id: String { rawValue }

        var label: String {
            switch self {
            case .seedPhrase: "Seed Phrase"
            case .privateKey: "Private Key"
            }
        }
    }

    private var isSeed: Bool { kindSelection != .privateKey }

    private var seedWordCount: Int {
        secret.split(whereSeparator: \.isWhitespace).count
    }

    /// A recognisable example for the selected chain, so the field reads as an
    /// input rather than a label.
    private var addressPlaceholder: String {
        switch chain {
        case .known(.bitcoin): "bc1q…"
        case .known(.evm): "0x…"
        case .known(.solana): "7f9d3Vbn…"
        case .known(.ton): "UQ…"
        case .known(.tron): "T…"
        case .known(.cardano): "addr1…"
        case .known(.xrp): "r…"
        case .known(.litecoin): "ltc1…"
        case .known(.monero): "4…"
        case .known(.cosmos): "cosmos1…"
        default: "Wallet address"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Main EVM Wallet"))
                    LabeledContent("Chain") {
                        Button {
                            showingChainPicker = true
                        } label: {
                            HStack(spacing: 8) {
                                ChainLogo(chain: chain, size: 20)
                                Text(chain.displayName)
                                    .foregroundStyle(.primary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Picker("Type", selection: $kindSelection) {
                        ForEach(KindSelection.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                Section {
                    TextEditor(text: $secret)
                        .font(.callout.monospaced())
                        .frame(minHeight: 80)
                        .autocorrectionDisabled()
                } header: {
                    Text(isSeed ? "Seed Phrase" : "Private Key")
                } footer: {
                    if isSeed {
                        // Flagged only at the lengths BIP-39 actually defines,
                        // so an in-progress paste is not scolded for being
                        // halfway typed.
                        Text("\(seedWordCount) words")
                            .foregroundStyle(SecretKind.isPlausibleWordCount(seedWordCount) ? Color.secondary : .orange)
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("", text: $publicAddress, prompt: Text(addressPlaceholder))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .labelsHidden()
                        if canDeriveAddress {
                            Button("Derive…") { showingDerivation = true }
                                .help("Work out the address from the secret, offline")
                        }
                    }
                } header: {
                    Text("Public Address")
                } footer: {
                    if canDeriveAddress {
                        Text("Optional. “Derive” computes the address from the secret on this Mac — nothing is sent anywhere. Matching it against your wallet confirms the secret was recorded correctly.")
                    } else {
                        Text("Optional. Storing it lets you confirm at a glance that this entry is the wallet you think it is — without revealing the secret.")
                    }
                }

                Section {
                    // Only groups belonging to the selected chain — a Solana
                    // wallet cannot live in a Bitcoin folder.
                    Picker("Group", selection: $groupID) {
                        Text("Ungrouped").tag(UUID?.none)
                        ForEach(session.groups(for: chain)) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                    .disabled(session.groups(for: chain).isEmpty)
                    Toggle("Favorite", isOn: $favorite)
                } footer: {
                    if session.groups(for: chain).isEmpty {
                        Text("No groups in \(chain.displayName) yet — right-click the chain in the sidebar to add one.")
                    }
                }

                Section {
                    TextField("", text: $tagsText, prompt: Text("hot, trading"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if !tagSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tagSuggestions, id: \.self) { tag in
                                    Button {
                                        appendTag(tag)
                                    } label: {
                                        Text(tag)
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.quaternary.opacity(0.6), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    if !tagSuggestions.isEmpty {
                        Text("Tap to add one you've used before.")
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New Wallet" : "Edit Wallet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear(perform: populate)
        .sheet(isPresented: $showingChainPicker) {
            ChainPickerView(selection: $chain)
        }
        .onChange(of: chain) { _, newChain in
            // Switching chains invalidates a group from the previous one.
            if let groupID, session.group(id: groupID)?.chain != newChain {
                self.groupID = nil
            }
        }
        .sheet(isPresented: $showingDerivation) {
            AddressDerivationView(
                chain: chain,
                kind: isSeed ? .seedPhrase(wordCount: seedWordCount) : .privateKey,
                secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                currentAddress: publicAddress.trimmingCharacters(in: .whitespaces)
            ) { derived in
                publicAddress = derived
            }
        }
    }

    private func populate() {
        guard let existing else {
            chain = session.settings.defaultChain
            return
        }
        name = existing.name
        secret = existing.secret
        publicAddress = existing.publicAddress ?? ""
        notes = existing.notes
        tagsText = existing.tags.joined(separator: ", ")
        favorite = existing.favorite
        groupID = existing.groupID
        chain = existing.chain
        switch existing.kind {
        case .privateKey: kindSelection = .privateKey
        case .seedPhrase: kindSelection = .seedPhrase
        }
    }

    private func save() {
        let kind: SecretKind = isSeed ? .seedPhrase(wordCount: seedWordCount) : .privateKey
        let tags = enteredTags

        var entry = existing ?? WalletEntry(name: "", chain: chain, kind: kind, secret: "")
        entry.name = name.trimmingCharacters(in: .whitespaces)
        entry.chain = chain
        entry.kind = kind
        entry.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.publicAddress = publicAddress.isEmpty ? nil : publicAddress.trimmingCharacters(in: .whitespaces)
        entry.notes = notes
        entry.tags = tags
        entry.groupID = groupID
        entry.favorite = favorite

        session.upsert(entry)
        dismiss()
    }
}
