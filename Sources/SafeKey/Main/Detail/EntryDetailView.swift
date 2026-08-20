import SwiftUI
import SafeKeyCore

struct EntryDetailView: View {
    let session: VaultSession
    let entry: WalletEntry
    @State private var isEditing = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ChainLogo(chain: entry.chain, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.title2.bold())
                        Text("\(entry.chain.displayName) · \(entry.kind.displayName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        session.toggleFavorite(id: entry.id)
                    } label: {
                        Image(systemName: entry.favorite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(entry.favorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(entry.favorite ? "Remove from Favorites" : "Add to Favorites")
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                SecretRevealRow(entry: entry, session: session)
            }

            if let address = entry.publicAddress, !address.isEmpty {
                Section {
                    LabeledContent("Public Address") {
                        HStack(spacing: 8) {
                            Text(address)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                            } label: {
                                Image(systemName: "document.on.document")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy address")
                        }
                    }
                }
            }

            if !entry.notes.isEmpty {
                Section("Notes") {
                    Text(entry.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !entry.tags.isEmpty {
                Section("Tags") {
                    HStack(spacing: 6) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                    }
                }
            }

            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Created \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Modified \(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            EntryEditView(session: session, existing: entry)
        }
    }
}
