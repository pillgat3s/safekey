import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

struct SettingsView: View {
    let session: VaultSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var biometricsEnabled = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var exportDocument: VaultBackupDocument?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var pendingRestore: Data?
    @State private var showingArmConfirmation = false
    @State private var armConfirmationText = ""
    @State private var includeInCloudBackup = true
    @State private var showingDefaultChainPicker = false
    @State private var showingRemoveSync = false
    @State private var showingReplaceCloud = false
    @State private var showingAdopt = false
    @State private var adoptPassword = ""
    @State private var adoptError: String?
    @State private var isAdopting = false
    @State private var showingMerge = false
    @State private var pendingMerge: (Vault.Unlocked, Int)?
    @State private var showingMergeConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if BiometricFactor.isBiometryAvailable() || biometricsEnabled {
                        Toggle("Unlock with \(model.biometryName)", isOn: biometricsBinding)
                    } else {
                        Text("Biometric unlock isn't available on this device.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Unlocking")
                }

                Section {
                    Button {
                        showingDefaultChainPicker = true
                    } label: {
                        HStack {
                            Text("Default chain").foregroundStyle(.primary)
                            Spacer()
                            ChainLogo(chain: session.settings.defaultChain, size: 22)
                            Text(session.settings.defaultChain.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("New Wallets")
                } footer: {
                    Text("Preselected when you add a wallet. You can still change it per wallet.")
                }

                Section {
                    Picker("Ask before revealing", selection: revealPolicyBinding) {
                        Text("Never").tag(RevealChoice.never)
                        Text("Every time").tag(RevealChoice.everyTime)
                        Text("After 5 minutes").tag(RevealChoice.after5)
                    }
                    Picker("Clear clipboard after", selection: clipboardBinding) {
                        Text("30 seconds").tag(30 as Int?)
                        Text("1 minute").tag(60 as Int?)
                        Text("2 minutes").tag(120 as Int?)
                        Text("Never").tag(nil as Int?)
                    }
                    NavigationLink("Change Master Password") {
                        ChangePasswordView(session: session)
                    }
                    Toggle("Erase after failed attempts", isOn: selfDestructBinding)
                    if session.header.selfDestruct.enabled {
                        Stepper(
                            "Allow \(session.header.selfDestruct.maxAttempts) attempts",
                            value: attemptsBinding,
                            in: SelfDestructPolicy.attemptRange
                        )
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("The vault locks whenever the app leaves the foreground.\n\nErase after failed attempts: that many wrong passwords in a row and SafeKey deletes the vault and every stored key — no undo, no recovery. A correct password resets the count. It protects a stolen phone, not a backup copy someone already took.")
                }

                Section {
                    Toggle("Sync with iCloud", isOn: cloudSyncBinding)
                    if session.settings.cloudSyncEnabled {
                        LabeledContent("Status") {
                            Text(syncStatusText).foregroundStyle(.secondary)
                        }
                        Button("Sync Now") {
                            Task { await model.sync.syncIfEnabled(session: session) }
                        }
                        if model.sync.status == .differentVault {
                            // Joining with the master password comes first: it
                            // is what the user usually wants, and it keeps both
                            // devices' data. Replacing discards one side.
                            // Merging keeps both sides, so it is offered first.
                            Button("Merge with the iCloud Vault…") {
                                adoptPassword = ""
                                showingMerge = true
                            }
                            Button("Use the iCloud Vault Here…") {
                                adoptPassword = ""
                                adoptError = nil
                                showingAdopt = true
                            }
                            Button("Replace iCloud Copy with This Vault", role: .destructive) {
                                showingReplaceCloud = true
                            }
                        }
                        Button("Stop Syncing and Remove Copy", role: .destructive) {
                            showingRemoveSync = true
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Wallets are kept in step across your Apple devices through your own iCloud account. Each one is uploaded already encrypted with your master password — iCloud stores it but cannot read it. Wallets edited on two devices at once are both kept, never merged silently.")
                }

                Section {
                    Toggle("Include in iCloud Backup", isOn: $includeInCloudBackup)
                        .onChange(of: includeInCloudBackup) { _, include in
                            setCloudBackup(include)
                        }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("When your iPhone backs up to iCloud, the vault goes with it — as the same encrypted file, still opening only with your master password. Turn this off and a lost or replaced iPhone takes the vault with it unless you exported a backup yourself.")
                }

                Section {
                    Button("Export Encrypted Backup…") { prepareExport() }
                    Button("Replace from Backup…", role: .destructive) { showingImporter = true }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Export a copy to keep somewhere else — iCloud Drive, another device, wherever you like. It is encrypted with your master password, so the copy is useless to anyone who does not have it.")
                }

                Section {
                    LabeledContent("Wallets", value: "\(session.entries.count)")
                    if let created = model.lockedHeader?.createdAt ?? session.header.createdAt as Date? {
                        LabeledContent("Vault created", value: created.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                biometricsEnabled = model.biometricFactor.isEnrolled(vaultID: session.header.vaultID)
                includeInCloudBackup = await !model.store.isExcludedFromBackup()
            }
            .sheet(isPresented: $showingDefaultChainPicker) {
                ChainPickerView(selection: defaultChainBinding)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .data,
                defaultFilename: "SafeKey Backup"
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                } else {
                    infoMessage = "Encrypted backup saved."
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): loadBackup(url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("Settings", isPresented: alertBinding(for: $errorMessage)) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("Backup", isPresented: alertBinding(for: $infoMessage)) {
                Button("OK", role: .cancel) {}
            } message: { Text(infoMessage ?? "") }
            .alert("Merge with the iCloud Vault", isPresented: $showingMerge) {
                SecureField("Master password", text: $adoptPassword)
                Button("Cancel", role: .cancel) { adoptPassword = "" }
                Button("Continue") { previewMerge() }
            } message: {
                Text("Enter the master password for the vault in iCloud. Its wallets are added to this device and yours are kept — nothing is removed. You will see how many would be added before anything changes.")
            }
            .alert("Add \(pendingMerge?.1 ?? 0) wallets?", isPresented: $showingMergeConfirm) {
                Button("Cancel", role: .cancel) { pendingMerge = nil }
                Button("Merge") { applyMerge() }
            } message: {
                Text("The iCloud vault has \(pendingMerge?.1 ?? 0) wallets that are not on this device. They will be added here and re-encrypted with this vault's master password, so from now on this password opens all of them.")
            }
            .alert("Use the iCloud Vault", isPresented: $showingAdopt) {
                SecureField("Master password", text: $adoptPassword)
                Button("Cancel", role: .cancel) { adoptPassword = "" }
                Button("Unlock") { adoptCloudVault() }
            } message: {
                Text("Enter the master password for the vault in iCloud. This device's current wallets are replaced by it — export a backup first if you want to keep them. A copy of the outgoing vault is kept in case this was a mistake.")
            }
            .confirmationDialog(
                "Replace the iCloud copy?",
                isPresented: $showingReplaceCloud,
                titleVisibility: .visible
            ) {
                Button("Replace", role: .destructive) {
                    Task { await model.sync.replaceCloudCopy(session: session) }
                }
            } message: {
                Text("iCloud holds a different vault — one created separately from this device's, so its wallets are sealed with a key this device does not have. Using the same master password on both does not make them the same vault.\n\nTo put this device's wallets everywhere: replace the iCloud copy, then restore this device's backup on the other one.\n\nTo keep the other device's wallets instead: export a backup there and restore it here — do not replace.")
            }
            .confirmationDialog(
                "Stop syncing and remove the iCloud copy?",
                isPresented: $showingRemoveSync,
                titleVisibility: .visible
            ) {
                Button("Remove from iCloud", role: .destructive) {
                    Task {
                        await model.sync.removeFromCloud(session: session)
                        var settings = session.settings
                        settings.cloudSyncEnabled = false
                        session.updateSettings(settings)
                    }
                }
            } message: {
                Text("The wallets on this device are kept. Only the copy in iCloud is deleted, and your other devices stop receiving changes.")
            }
            .alert("Arm self-destruct?", isPresented: $showingArmConfirmation) {
                TextField("Type DELETE", text: $armConfirmationText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { armConfirmationText = "" }
                Button("Arm", role: .destructive) { confirmArm() }
                    .disabled(armConfirmationText != "DELETE")
            } message: {
                Text("Once armed, \(session.header.selfDestruct.maxAttempts) wrong passwords in a row will erase this vault permanently. Type DELETE to confirm you understand.")
            }
            .alert("Replace this vault?", isPresented: restoreBinding) {
                Button("Cancel", role: .cancel) { pendingRestore = nil }
                Button("Replace", role: .destructive) { confirmRestore() }
            } message: {
                Text("This erases the vault on this device and replaces it with the backup. You will unlock it with the backup's own master password.")
            }
        }
    }

    // MARK: - Bindings

    private enum RevealChoice: Hashable { case never, everyTime, after5 }

    private func alertBinding(for message: Binding<String?>) -> Binding<Bool> {
        Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    private var revealPolicyBinding: Binding<RevealChoice> {
        Binding(
            get: {
                switch session.settings.revealPolicy {
                case .never: .never
                case .everyTime: .everyTime
                case .afterMinutes: .after5
                }
            },
            set: { choice in
                var settings = session.settings
                settings.revealPolicy = switch choice {
                case .never: .never
                case .everyTime: .everyTime
                case .after5: .afterMinutes(5)
                }
                session.updateSettings(settings)
            }
        )
    }

    private var clipboardBinding: Binding<Int?> {
        Binding(
            get: { session.settings.clipboardClearSeconds },
            set: { newValue in
                var settings = session.settings
                settings.clipboardClearSeconds = newValue
                session.updateSettings(settings)
            }
        )
    }

    /// Arming is deliberately harder than disarming: turning it on routes
    /// through a typed confirmation, turning it off is immediate.
    private var selfDestructBinding: Binding<Bool> {
        Binding(
            get: { session.header.selfDestruct.enabled },
            set: { enable in
                if enable {
                    armConfirmationText = ""
                    showingArmConfirmation = true
                } else {
                    session.updateHeader { $0.selfDestruct.enabled = false }
                }
            }
        )
    }

    private func confirmArm() {
        guard armConfirmationText == "DELETE" else { return }
        armConfirmationText = ""
        session.updateHeader { $0.selfDestruct.enabled = true }
    }

    private var attemptsBinding: Binding<Int> {
        Binding(
            get: { session.header.selfDestruct.maxAttempts },
            set: { newValue in session.updateHeader { $0.selfDestruct.maxAttempts = newValue } }
        )
    }

    private func previewMerge() {
        let password = adoptPassword
        adoptPassword = ""
        Task {
            do {
                let result = try await model.previewCloudMerge(password: password)
                if result.1 == 0 {
                    infoMessage = "Nothing to add — the iCloud vault holds no wallets this device is missing."
                } else {
                    pendingMerge = result
                    showingMergeConfirm = true
                }
            } catch VaultError.wrongPassword {
                errorMessage = "That password does not open the vault in iCloud."
            } catch {
                errorMessage = "Could not read the iCloud vault: \(error.localizedDescription)"
            }
        }
    }

    private func applyMerge() {
        guard let (merged, count) = pendingMerge else { return }
        pendingMerge = nil
        Task {
            do {
                try await model.applyCloudMerge(merged)
                infoMessage = "Added \(count) wallets from iCloud."
            } catch {
                errorMessage = "Could not merge: \(error.localizedDescription)"
            }
        }
    }

    private func adoptCloudVault() {
        let password = adoptPassword
        adoptPassword = ""
        isAdopting = true
        Task {
            defer { isAdopting = false }
            do {
                try await model.adoptCloudVault(password: password)
                dismiss()
            } catch VaultError.wrongPassword {
                errorMessage = "That password does not open the vault in iCloud."
            } catch {
                errorMessage = "Could not use the iCloud vault: \(error.localizedDescription)"
            }
        }
    }

    private var syncStatusText: String {
        switch model.sync.status {
        case .off: "Off"
        case .unavailable(let reason): reason
        case .idle(let date):
            date.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Waiting"
        case .syncing: "Syncing…"
        case .failed(let reason): reason
        case .differentVault: "iCloud holds a different vault"
        }
    }

    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { session.settings.cloudSyncEnabled },
            set: { enabled in
                var settings = session.settings
                settings.cloudSyncEnabled = enabled
                session.updateSettings(settings)
                if enabled {
                    Task { await model.sync.syncIfEnabled(session: session) }
                }
            }
        )
    }

    private var defaultChainBinding: Binding<Chain> {
        Binding(
            get: { session.settings.defaultChain },
            set: { newValue in
                var settings = session.settings
                settings.defaultChain = newValue
                session.updateSettings(settings)
            }
        )
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { biometricsEnabled },
            set: { enable in
                // Move the switch straight away and put it back if the attempt
                // fails. Leaving it off until Face ID returns makes the tap
                // look ignored for as long as the prompt is up.
                biometricsEnabled = enable
                if enable {
                    Task {
                        do {
                            _ = try await model.enableBiometricUnlock()
                        } catch BiometricError.cancelled {
                            biometricsEnabled = false
                        } catch {
                            errorMessage = "Could not enable \(model.biometryName): \(error.localizedDescription)"
                            biometricsEnabled = false
                        }
                    }
                } else {
                    do {
                        try model.disableBiometricUnlock()
                    } catch {
                        errorMessage = error.localizedDescription
                        biometricsEnabled = true
                    }
                }
            }
        )
    }

    private func setCloudBackup(_ include: Bool) {
        Task {
            do {
                try await model.store.setExcludedFromBackup(!include)
            } catch {
                errorMessage = "Could not change the iCloud backup setting: \(error.localizedDescription)"
                includeInCloudBackup = await !model.store.isExcludedFromBackup()
            }
        }
    }

    // MARK: - Backup

    private func prepareExport() {
        do {
            exportDocument = VaultBackupDocument(data: try model.exportVaultData())
            showingExporter = true
        } catch {
            errorMessage = "Could not prepare the backup: \(error.localizedDescription)"
        }
    }

    private func loadBackup(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try model.inspectBackup(data)
            pendingRestore = data
        } catch {
            errorMessage = "That file is not a valid SafeKey backup."
        }
    }

    private func confirmRestore() {
        guard let data = pendingRestore else { return }
        pendingRestore = nil
        Task {
            do {
                try await model.importVault(data)
                dismiss()
            } catch {
                errorMessage = "Could not restore the backup: \(error.localizedDescription)"
            }
        }
    }
}

/// Wrapper so the encrypted container can go through the system file exporter.
/// Carries the sealed bytes untouched — no decryption anywhere in this path.
struct VaultBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
