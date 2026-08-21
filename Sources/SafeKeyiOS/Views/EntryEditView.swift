import SwiftUI
import SafeKeyCore

struct EntryEditView: View {
    let session: VaultSession
    var existing: WalletEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chain: Chain = .evm
    @State private var isSeedPhrase = true
    @State private var secret = ""
    @State private var publicAddress = ""
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var favorite = false
    @State private var showingChainPicker = false
    @State private var groupID: UUID?
    @State private var newGroupName = ""
    @State private var showingNewGroup = false
    @State private var derivedAddresses: [SolanaAddress.Candidate] = []
    @State private var derivationError: String?
    @State private var isDeriving = false

    private var wordCount: Int {
        secret.split(whereSeparator: \.isWhitespace).count
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canDerive: Bool {
        chain == .solana && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Main Wallet"))
                        .accessibilityIdentifier("entry.name")
                    Button {
                        showingChainPicker = true
                    } label: {
                        HStack {
                            Text("Chain").foregroundStyle(.primary)
                            Spacer()
                            ChainLogo(chain: chain, size: 22)
                            Text(chain.displayName).foregroundStyle(.secondary)
                        }
                    }
                    // Groups belong to a chain, so the choices change with it
                    // and a group from the old chain must not linger.
                    Picker("Group", selection: $groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(session.groups(for: chain)) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                    Button("New Group…") {
                        newGroupName = ""
                        showingNewGroup = true
                    }
                    Picker("Type", selection: $isSeedPhrase) {
                        Text("Seed Phrase").tag(true)
                        Text("Private Key").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextEditor(text: $secret)
                        .accessibilityIdentifier("entry.secret")
                        .font(.callout.monospaced())
                        .frame(minHeight: 90)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text(isSeedPhrase ? "Seed Phrase" : "Private Key")
                } footer: {
                    if isSeedPhrase {
                        Text("\(wordCount) words")
                            .foregroundStyle(
                                SecretKind.isPlausibleWordCount(wordCount)
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(Color.orange)
                            )
                    }
                }

                Section {
                    TextField("Public address (optional)", text: $publicAddress)
                        .accessibilityIdentifier("entry.address")
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if canDerive {
                        Button {
                            derive()
                        } label: {
                            if isDeriving {
                                ProgressView()
                            } else {
                                Label("Derive from Secret", systemImage: "wand.and.sparkles")
                            }
                        }
                        .disabled(isDeriving)
                    }
                    ForEach(derivedAddresses) { candidate in
                        Button {
                            publicAddress = candidate.address
                            derivedAddresses = []
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.address)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(candidate.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let derivationError {
                        Text(derivationError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Public Address")
                } footer: {
                    if canDerive {
                        Text("Derived on this device — nothing is sent anywhere. Matching it against your wallet confirms the secret was recorded correctly.")
                    }
                }

                Section {
                    TextField("Tags (comma separated)", text: $tagsText)
                        .accessibilityIdentifier("entry.tags")
                        .autocorrectionDisabled()
                    if !tagSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tagSuggestions, id: \.self) { tag in
                                    Button(tag) { appendTag(tag) }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    Toggle("Favorite", isOn: $favorite)
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }
            }
            .navigationTitle(existing == nil ? "New Wallet" : "Edit Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingChainPicker) {
                ChainPickerView(selection: $chain)
            }
            .onChange(of: chain) { _, newChain in
                if let groupID, !session.groups(for: newChain).contains(where: { $0.id == groupID }) {
                    self.groupID = nil
                }
            }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Group name", text: $newGroupName)
                Button("Cancel", role: .cancel) { newGroupName = "" }
                Button("Create") { createGroup() }
            } message: {
                Text("Groups organise wallets within \(chain.displayName).")
            }
            .onAppear(perform: populate)
        }
    }

    private var enteredTags: [String] {
        tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var tagSuggestions: [String] {
        let used = Set(enteredTags.map { $0.lowercased() })
        return session.tagsByFrequency.filter { !used.contains($0.lowercased()) }.prefix(10).map { $0 }
    }

    private func appendTag(_ tag: String) {
        tagsText = (enteredTags + [tag]).joined(separator: ", ")
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        newGroupName = ""
        guard !name.isEmpty else { return }
        groupID = session.addGroup(name: name, chain: chain, colorHex: nil).id
    }

    private func populate() {
        guard let existing else {
            chain = session.settings.defaultChain
            return
        }
        name = existing.name
        chain = existing.chain
        isSeedPhrase = existing.kind.isSeedPhrase
        secret = existing.secret
        publicAddress = existing.publicAddress ?? ""
        notes = existing.notes
        tagsText = existing.tags.joined(separator: ", ")
        favorite = existing.favorite
        groupID = existing.groupID
    }

    private func derive() {
        isDeriving = true
        derivationError = nil
        let kind: SecretKind = isSeedPhrase ? .seedPhrase(wordCount: wordCount) : .privateKey
        let entry = WalletEntry(name: "", chain: chain, kind: kind, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            defer { isDeriving = false }
            let result = await Task.detached { Result { try SolanaAddress.candidates(for: entry) } }.value
            switch result {
            case .success(let candidates):
                derivedAddresses = Array(candidates.prefix(6))
            case .failure:
                derivationError = "Could not derive an address from this secret."
            }
        }
    }

    private func save() {
        let kind: SecretKind = isSeedPhrase ? .seedPhrase(wordCount: wordCount) : .privateKey
        var entry = existing ?? WalletEntry(name: "", chain: chain, kind: kind, secret: "")
        entry.name = name.trimmingCharacters(in: .whitespaces)
        entry.chain = chain
        entry.kind = kind
        entry.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.publicAddress = publicAddress.isEmpty ? nil : publicAddress.trimmingCharacters(in: .whitespaces)
        entry.notes = notes
        entry.tags = enteredTags
        entry.favorite = favorite
        entry.groupID = groupID
        session.upsert(entry)
        dismiss()
    }
}

struct ChainPickerView: View {
    @Binding var selection: Chain
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var customName = ""

    private var matches: [Chain] {
        guard !search.isEmpty else { return Chain.catalog }
        return Chain.catalog.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.shortCode.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches, id: \.self) { chain in
                        Button {
                            selection = chain
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ChainLogo(chain: chain, size: 30)
                                Text(chain.displayName).foregroundStyle(.primary)
                                Spacer()
                                if chain == selection {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("Chain name", text: $customName, prompt: Text("e.g. Kaspa"))
                    Button("Use This Name") {
                        selection = .custom(customName.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Not listed?")
                } footer: {
                    Text("For a network with its own key format. Layer 2s and EVM-compatible chains all use EVM keys — pick EVM for those.")
                }
            }
            .searchable(text: $search, prompt: "Search chains")
            .navigationTitle("Chain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
