import SwiftUI
import SafeKeyCore

/// Create or rename a group, with a colour so the sidebar stays scannable once
/// there are more than a handful.
struct GroupEditorView: View {
    let session: VaultSession
    /// Groups belong to exactly one chain, fixed at creation.
    let chain: Chain
    var existing: WalletGroup?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = WalletGroup.palette[0]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ChainLogo(chain: chain, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(existing == nil ? "New Group" : "Rename Group")
                        .font(.title3.bold())
                    Text("in \(chain.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Name", text: $name, prompt: Text("e.g. Trading, Cold Storage"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSave { save() } }

            VStack(alignment: .leading, spacing: 6) {
                Text("Colour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(WalletGroup.palette, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if hex == colorHex {
                                        Circle().strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(existing == nil ? "Create" : "Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 340)
        .onAppear {
            if let existing {
                name = existing.name
                colorHex = existing.colorHex ?? WalletGroup.palette[0]
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing {
            existing.name = trimmed
            existing.colorHex = colorHex
            session.updateGroup(existing)
        } else {
            session.addGroup(name: trimmed, chain: chain, colorHex: colorHex)
        }
        dismiss()
    }
}
