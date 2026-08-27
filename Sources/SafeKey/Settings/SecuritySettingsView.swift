import SwiftUI
import AppKit
import SafeKeyCore

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    let session: VaultSession

    @State private var showingChangePassword = false
    @State private var showingAdopt = false
    @State private var adoptPassword = ""
    @State private var adoptError: String?
    @State private var mergeMode = false
    @State private var pendingMerge: (Vault.Unlocked, Int)?
    @State private var showingDeviceKeySetup = false
    @State private var showingDeviceKeyDisable = false
    @State private var biometricsEnabled = false
    @State private var biometricStrategy: BiometricFactor.Strategy?
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pendingRestore: (data: Data, header: VaultHeader)?
    @State private var showingReplaceCloud = false
    @State private var showingRemoveSync = false

    var body: some View {
        Form {
            Section("Master Password") {
                LabeledContent("Password") {
                    Button("Change Password…") { showingChangePassword = true }
                }
            }

            Section {
                if BiometricFactor.isBiometryAvailable() || biometricsEnabled {
                    Toggle("Unlock with Touch ID", isOn: biometricsBinding)
                    if biometricsEnabled, let biometricStrategy {
                        LabeledContent("Protection") {
                            Text(
                                biometricStrategy == .accessControl
                                    ? "Keychain-enforced (biometry bound to the item)"
                                    : "App-enforced (ad-hoc signed build fallback)"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Touch ID is not available on this Mac.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Touch ID")
            } footer: {
                if session.header.unlockPolicy.requiresDevice {
                    Text("With the security key required, Touch ID also needs the key inserted.")
                }
            }

            Section {
                if session.header.unlockPolicy.requiresDevice {
                    LabeledContent("Status") {
                        Label("Required — \(session.header.unlockPolicy.volumeName ?? "security key")", systemImage: "mediastick")
                            .foregroundStyle(.green)
                    }
                    Button("Export Backup Key…") { exportBackup() }
                    Button("Remove Requirement…", role: .destructive) { showingDeviceKeyDisable = true }
                } else {
                    LabeledContent("Status") {
                        Text("Not required").foregroundStyle(.secondary)
                    }
                    Button("Require a Security Key…") { showingDeviceKeySetup = true }
                }
            } header: {
                Text("USB Security Key")
            } footer: {
                Text("When enabled, the vault key is cryptographically bound to a key file on your USB device. The correct password without the device cannot open the vault — and losing the device (and its backup) makes the vault permanently unrecoverable.")
            }

            Section("Revealing Secrets") {
                Picker("Ask for authentication", selection: revealPolicyBinding) {
                    Text("Never").tag(RevealChoice.never)
                    Text("Every time").tag(RevealChoice.everyTime)
                    Text("After 5 minutes").tag(RevealChoice.after5)
                    Text("After 15 minutes").tag(RevealChoice.after15)
                }
            }

            Section("Auto-Lock") {
                Toggle("Lock when the Mac sleeps", isOn: settingsBinding(\.lockOnSleep))
                Toggle("Lock when the screen locks", isOn: settingsBinding(\.lockOnScreenLock))
                Picker("Lock after inactivity", selection: autoLockBinding) {
                    Text("1 minute").tag(60 as Int?)
                    Text("5 minutes").tag(300 as Int?)
                    Text("15 minutes").tag(900 as Int?)
                    Text("1 hour").tag(3600 as Int?)
                    Text("Never").tag(nil as Int?)
                }
            }

            Section("Clipboard") {
                Picker("Clear copied secrets after", selection: clipboardBinding) {
                    Text("10 seconds").tag(10 as Int?)
                    Text("30 seconds").tag(30 as Int?)
                    Text("1 minute").tag(60 as Int?)
                    Text("2 minutes").tag(120 as Int?)
                    Text("Never").tag(nil as Int?)
                }
            }

            Section {
                Toggle("Hide SafeKey from screen capture", isOn: captureBinding)
            } header: {
                Text("On Screen")
            } footer: {
                Text("When on, SafeKey's windows come out blank in screenshots, screen recordings, and screen sharing — anyone capturing this screen gets an empty rectangle where the vault is. Turn it off to include SafeKey in your own captures. Takes effect immediately.")
                    .font(.caption)
            }

            Section {
                Toggle("Sync with iCloud", isOn: cloudSyncBinding)
                if session.settings.cloudSyncEnabled {
                    LabeledContent("Status") {
                        Text(syncStatusText).foregroundStyle(.secondary)
                    }
                    if model.sync.status == .differentVault {
                        Text("iCloud holds a different vault — one created separately from this Mac's, so its wallets are sealed with a key this Mac does not have.\n\nMerge keeps both sides: its wallets are added to this vault, re-encrypted under this vault's master password. Use the iCloud Vault replaces what is on this Mac with it. Replace erases the iCloud copy and puts this vault there instead.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            // Joining keeps both devices' data; replacing
                            // discards one side, so it is the second option.
                            // Merging keeps both sides, so it comes first.
                            Button("Merge with the iCloud Vault…") {
                                adoptPassword = ""
                                adoptError = nil
                                mergeMode = true
                                showingAdopt = true
                            }
                            Button("Use the iCloud Vault Here…") {
                                adoptPassword = ""
                                adoptError = nil
                                mergeMode = false
                                showingAdopt = true
                            }
                            Button("Replace iCloud Copy with This Vault") {
                                showingReplaceCloud = true
                            }
                        }
                    }
                    HStack {
                        Button("Sync Now") {
                            Task { await model.sync.syncIfEnabled(session: session) }
                        }
                        Button("Stop Syncing and Remove Copy") {
                            showingRemoveSync = true
                        }
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Keeps wallets in step across your Apple devices through your own iCloud account. Each wallet is uploaded already encrypted with your master password — iCloud stores it but cannot read it. A wallet edited on two devices at once is kept twice rather than merged silently.")
            }

            Section {
                if CloudBackupService.shared.isAvailable {
                    Toggle("Keep an encrypted copy in iCloud Drive", isOn: cloudBackupBinding)
                    if session.settings.cloudBackupEnabled {
                        LabeledContent("Last copied") {
                            Text(CloudBackupService.shared.lastBackupDate
                                .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                                .foregroundStyle(.secondary)
                        }
                        Button("Back Up Now") { backUpToCloudNow() }
                    }
                    if let cloudError = model.cloudBackupError {
                        Label(cloudError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                } else {
                    Text("iCloud Drive is off. Turn it on in System Settings → Apple Account → iCloud to use this.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Only the encrypted vault file is uploaded — the same sealed file stored on this Mac. It can be opened solely with your master password, so iCloud never holds anything readable. Updated automatically after every change.")
            }

            Section {
                Button("Export Encrypted Backup…") { exportVaultBackup() }
                Button("Replace from Backup…", role: .destructive) { pickRestoreFile() }
            } header: {
                Text("Backup")
            } footer: {
                Text("The backup is the same encrypted file stored on this Mac — it can only be opened with this vault's master password (and security key, if enabled), so it is safe to keep in iCloud Drive, on a USB stick, or anywhere else. Keep one: if this Mac is lost, the backup is the only way to recover your keys.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAdopt) { adoptSheet }
        .confirmationDialog(
            "Add \(pendingMerge?.1 ?? 0) wallets from iCloud?",
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge") { applyMerge() }
            Button("Cancel", role: .cancel) { pendingMerge = nil }
        } message: {
            Text("These wallets are not on this Mac. They will be added and re-encrypted with this vault's master password, so from now on that password opens all of them.")
        }
        .frame(width: 520, height: 620)
        .onAppear(perform: refreshBiometricState)
        .sheet(isPresented: $showingChangePassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showingDeviceKeySetup) {
            DeviceKeySetupView()
        }
        .sheet(isPresented: $showingDeviceKeyDisable) {
            DeviceKeyDisableView()
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
            Text("iCloud holds a different vault, and replacing erases its copy there for good. If it has wallets you want to keep, cancel and choose “Merge with the iCloud Vault” instead — merging keeps both sides. Your other device keeps its own local copy and is offered the same choices the next time it syncs.")
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
            Text("The wallets on this Mac are kept. Only the copy in iCloud is deleted, and your other devices stop receiving changes.")
        }
        .alert("Security Settings", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Backup", isPresented: infoBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
        .alert("Replace this vault with the backup?", isPresented: restoreBinding) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Replace", role: .destructive) { confirmRestore() }
        } message: {
            Text("This erases the vault currently on this Mac and replaces it with the backup, created \(pendingRestore.map { $0.header.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"). You will unlock it with the backup's own master password. Export a backup of the current vault first if you might still need it.")
        }
    }

    // MARK: - Bindings

    private enum RevealChoice: Hashable {
        case never, everyTime, after5, after15
    }

    private var revealPolicyBinding: Binding<RevealChoice> {
        Binding(
            get: {
                switch session.settings.revealPolicy {
                case .never: .never
                case .everyTime: .everyTime
                case .afterMinutes(let minutes): minutes <= 5 ? .after5 : .after15
                }
            },
            set: { choice in
                var settings = session.settings
                settings.revealPolicy = switch choice {
                case .never: .never
                case .everyTime: .everyTime
                case .after5: .afterMinutes(5)
                case .after15: .afterMinutes(15)
                }
                session.updateSettings(settings)
            }
        )
    }

    private func settingsBinding(_ keyPath: WritableKeyPath<VaultSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { session.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = session.settings
                settings[keyPath: keyPath] = newValue
                session.updateSettings(settings)
                model.refreshAutoLock()
            }
        )
    }

    private var autoLockBinding: Binding<Int?> {
        Binding(
            get: { session.settings.autoLockSeconds },
            set: { newValue in
                var settings = session.settings
                settings.autoLockSeconds = newValue
                session.updateSettings(settings)
                model.refreshAutoLock()
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

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { biometricsEnabled },
            set: { enable in
                if enable {
                    Task { await enableBiometrics() }
                } else {
                    do {
                        try model.disableBiometricUnlock()
                        biometricsEnabled = false
                        biometricStrategy = nil
                    } catch {
                        errorMessage = "Could not remove the stored Touch ID key: \(error.localizedDescription)"
                    }
                }
            }
        )
    }

    /// Enabling asks for Touch ID first, the way iOS does: it proves the sensor
    /// works before the vault relies on it, and stops anyone at an already
    /// unlocked vault enrolling themselves. The toggle stays off unless the
    /// prompt succeeds.
    private func enableBiometrics() async {
        do {
            let deviceKey = session.header.unlockPolicy.requiresDevice
                ? model.deviceKeyProvider.locateDeviceKey(policy: session.header.unlockPolicy)
                : nil
            biometricStrategy = try await model.enableBiometricUnlock(deviceKey: deviceKey)
            biometricsEnabled = true
        } catch BiometricError.cancelled {
            biometricsEnabled = false
        } catch BiometricError.unavailable {
            errorMessage = "Touch ID isn't available on this Mac right now."
            biometricsEnabled = false
        } catch VaultError.deviceKeyRequired {
            errorMessage = "Insert your security key first — the Touch ID copy must be bound to it."
            biometricsEnabled = false
        } catch {
            errorMessage = "Could not enable Touch ID: \(error.localizedDescription)"
            biometricsEnabled = false
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var infoBinding: Binding<Bool> {
        Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    private var adoptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mergeMode ? "Merge with the iCloud Vault" : "Use the iCloud Vault").font(.headline)
            Text(mergeMode
                 ? "Enter the master password for the vault in iCloud. Its wallets are added to this Mac and yours are kept — nothing is removed. You will see how many would be added before anything changes."
                 : "Enter the master password for the vault in iCloud. This Mac's current wallets are replaced by it — export a backup first if you want to keep them. A copy of the outgoing vault is kept in case this was a mistake.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Master password", text: $adoptPassword)
                .textFieldStyle(.roundedBorder)
            if let adoptError {
                Text(adoptError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingAdopt = false }
                Button(mergeMode ? "Continue" : "Unlock") {
                    showingAdopt = false
                    if mergeMode { previewMerge() } else { adoptCloudVault() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(adoptPassword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func previewMerge() {
        let password = adoptPassword
        adoptPassword = ""
        Task {
            do {
                let result = try await model.previewCloudMerge(password: password)
                if result.1 == 0 {
                    adoptError = "Nothing to add — iCloud holds no wallets this Mac is missing."
                } else {
                    pendingMerge = result
                }
            } catch VaultError.wrongPassword {
                adoptError = "That password does not open the vault in iCloud."
            } catch {
                adoptError = "Could not read the iCloud vault: \(error.localizedDescription)"
            }
        }
    }

    private func applyMerge() {
        guard let (merged, _) = pendingMerge else { return }
        pendingMerge = nil
        Task {
            do {
                try await model.applyCloudMerge(merged)
            } catch {
                adoptError = "Could not merge: \(error.localizedDescription)"
            }
        }
    }

    private func adoptCloudVault() {
        let password = adoptPassword
        adoptPassword = ""
        Task {
            do {
                try await model.adoptCloudVault(password: password)
            } catch VaultError.wrongPassword {
                adoptError = "That password does not open the vault in iCloud."
            } catch {
                adoptError = "Could not use the iCloud vault: \(error.localizedDescription)"
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

    private var captureBinding: Binding<Bool> {
        Binding(
            get: { session.settings.effectiveBlockScreenCapture },
            set: { newValue in
                var settings = session.settings
                settings.blockScreenCapture = newValue
                session.updateSettings(settings)
            }
        )
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

    private var cloudBackupBinding: Binding<Bool> {
        Binding(
            get: { session.settings.cloudBackupEnabled },
            set: { enabled in
                var settings = session.settings
                settings.cloudBackupEnabled = enabled
                session.updateSettings(settings)
                if enabled {
                    // Copy immediately so the toggle means something now,
                    // rather than only after the next edit.
                    backUpToCloudNow()
                }
            }
        )
    }

    private func backUpToCloudNow() {
        do {
            try model.backUpToCloudNow()
            infoMessage = "Encrypted copy saved to iCloud Drive."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Backup / restore

    private func exportVaultBackup() {
        do {
            let data = try model.exportVaultData()
            let panel = NSSavePanel()
            panel.title = "Export Encrypted Backup"
            panel.nameFieldStringValue = "SafeKey Backup \(Date().formatted(.iso8601.year().month().day())).safekey"
            panel.allowedContentTypes = []
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            infoMessage = "Encrypted backup saved. It opens only with this vault's master password."
        } catch {
            errorMessage = "Could not export the backup: \(error.localizedDescription)"
        }
    }

    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a SafeKey Backup"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let header = try model.inspectBackup(data)   // throws if not a real container
            pendingRestore = (data, header)
        } catch {
            errorMessage = "That file is not a valid SafeKey backup."
        }
    }

    private func confirmRestore() {
        guard let restore = pendingRestore else { return }
        pendingRestore = nil
        Task {
            do {
                try await model.importVault(restore.data)
                // The window is now on the lock screen for the imported vault.
            } catch {
                errorMessage = "Could not restore the backup: \(error.localizedDescription)"
            }
        }
    }

    private func refreshBiometricState() {
        let vaultID = session.header.vaultID
        // Reflect whether the key is actually still there, not just whether a
        // marker says it once was.
        biometricsEnabled = model.biometricFactor.isEnrolled(vaultID: vaultID)
        biometricStrategy = biometricsEnabled ? model.biometricFactor.activeStrategy(vaultID: vaultID) : nil
        if !biometricsEnabled, model.biometricFactor.isEnabled(vaultID: vaultID) {
            // Stale marker from a reinstall — drop it so the toggle is honest.
            model.biometricFactor.forgetStrategyMarker(vaultID: vaultID)
        }
    }

    private func exportBackup() {
        guard let deviceKey = model.deviceKeyProvider.locateDeviceKey(policy: session.header.unlockPolicy) else {
            errorMessage = "Insert the security key first — the backup is a copy of its key file."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "safekey-device-backup.key"
        panel.title = "Export Backup Key"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try deviceKey.write(to: url)
            } catch {
                errorMessage = "Could not write the backup: \(error.localizedDescription)"
            }
        }
    }
}
