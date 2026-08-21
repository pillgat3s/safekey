import SwiftUI
import SafeKeyCore

/// Shows the addresses a stored secret produces, so the user can pick the one
/// their wallet shows — which simultaneously proves the secret was recorded
/// correctly.
///
/// Everything here is local arithmetic. No network call is made, and none
/// should ever be added: asking a block explorer about an address would leak
/// the link between this machine and the wallet.
struct AddressDerivationView: View {
    let chain: Chain
    let kind: SecretKind
    let secret: String
    /// Currently stored address, highlighted when it matches a derived one.
    let currentAddress: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [SolanaAddress.Candidate] = []
    @State private var derivationPassphrase = ""
    @State private var errorMessage: String?
    @State private var isWorking = true

    var body: some View {
        NavigationStack {
            Group {
                if isWorking {
                    ProgressView("Deriving…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Can't Derive", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else {
                    List {
                        if kind.isSeedPhrase {
                            Section {
                                SecureField("BIP-39 passphrase (optional)", text: $derivationPassphrase)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { Task { await derive() } }
                                Button("Derive Again") { Task { await derive() } }
                            } footer: {
                                Text("If none of these match your wallet, it most likely uses a BIP-39 passphrase — the optional \"25th word\" set when the wallet was created. Without it the addresses are completely different.")
                                    .font(.caption)
                            }
                        }

                        Section {
                            ForEach(candidates) { candidate in
                                row(candidate)
                            }
                        } footer: {
                            Text(footerText)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Derived Addresses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .task(id: secret) { await derive() }
    }

    private var footerText: String {
        if kind.isSeedPhrase {
            return "A seed phrase produces unlimited addresses — which one your wallet shows depends on its derivation path. Pick the one that matches. If none match, the phrase may be recorded incorrectly."
        }
        return "A private key determines exactly one address. If this doesn't match your wallet, the stored key is wrong."
    }

    private func row(_ candidate: SolanaAddress.Candidate) -> some View {
        let matchesStored = !currentAddress.isEmpty && candidate.address == currentAddress
        return Button {
            onPick(candidate.address)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.address)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(candidate.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(candidate.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if matchesStored {
                    Label("Matches", systemImage: "checkmark.seal.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("Matches the address already saved")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.address, forType: .string)
            }
        }
    }

    private func derive() async {
        isWorking = true
        errorMessage = nil
        let entry = WalletEntry(name: "", chain: chain, kind: kind, secret: secret)
        let passphrase = derivationPassphrase
        // PBKDF2 over 2048 rounds per candidate — off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            Result { try SolanaAddress.candidates(for: entry, passphrase: passphrase) }
        }.value
        switch result {
        case .success(let derived):
            candidates = derived
        case .failure(let error):
            candidates = []
            errorMessage = Self.message(for: error)
        }
        isWorking = false
    }

    private static func message(for error: any Error) -> String {
        guard let error = error as? SolanaAddress.DerivationError else {
            return "Could not derive an address from this secret."
        }
        switch error {
        case .unsupportedChain:
            return "Address derivation is currently implemented for Solana only."
        case .badWordCount(let count):
            return "A seed phrase must be 12, 15, 18, 21 or 24 words — this one has \(count)."
        case .notAMnemonic:
            return "This doesn't look like a seed phrase. Check for stray characters or numbers."
        case .unrecognisedPrivateKeyFormat:
            return "Unrecognised private key. SafeKey accepts Base58, a solana-keygen JSON array, or hex."
        case .failed:
            return "Derivation failed."
        }
    }
}
