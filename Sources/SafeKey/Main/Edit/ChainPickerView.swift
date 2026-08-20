import SwiftUI
import SafeKeyCore

/// Searchable chain list with a custom-chain escape hatch, so a wallet on a
/// network that isn't in the catalogue is a first-class entry rather than an
/// unsupported one.
struct ChainPickerView: View {
    @Binding var selection: Chain
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var customName = ""
    @FocusState private var customFieldFocused: Bool

    private var matches: [Chain] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Chain.catalog }
        return Chain.catalog.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.shortCode.localizedCaseInsensitiveContains(query)
                || subtitle(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    /// The current custom name, or the existing custom selection being edited.
    private var trimmedCustom: String {
        customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches, id: \.self) { chain in
                        row(for: chain)
                    }
                } header: {
                    Text(search.isEmpty ? "Chains" : "Results")
                }

                Section {
                    HStack(spacing: 10) {
                        ChainLogo(chain: .custom(trimmedCustom.isEmpty ? "?" : trimmedCustom), size: 26)
                        TextField("Chain name", text: $customName, prompt: Text("e.g. Kaspa"))
                            .textFieldStyle(.plain)
                            .focused($customFieldFocused)
                            .onSubmit(commitCustom)
                        Button("Use", action: commitCustom)
                            .buttonStyle(.borderless)
                            .disabled(trimmedCustom.isEmpty)
                    }
                } header: {
                    Text("Not listed?")
                } footer: {
                    Text("For a network with its own key format that isn't listed. Layer 2s and EVM-compatible chains — Base, Arbitrum, Polygon, BNB Smart Chain — all use EVM keys, so pick EVM for those.")
                }
            }
            .listStyle(.inset)
            .searchable(text: $search, placement: .toolbar, prompt: "Search chains")
            .navigationTitle("Choose Chain")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            if case .custom(let name) = selection { customName = name }
        }
    }

    private func row(for chain: Chain) -> some View {
        Button {
            selection = chain
            dismiss()
        } label: {
            HStack(spacing: 10) {
                ChainLogo(chain: chain, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chain.displayName)
                        .foregroundStyle(.primary)
                    Text(subtitle(for: chain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if chain == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for chain: Chain) -> String {
        if case .known(let known) = chain { return known.subtitle }
        return "Custom"
    }

    private func commitCustom() {
        guard !trimmedCustom.isEmpty else { return }
        selection = .custom(trimmedCustom)
        dismiss()
    }
}
