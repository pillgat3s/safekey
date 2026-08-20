import SwiftUI
import AppKit
import SafeKeyCore

/// Setup flow for the USB security key: pick a volume → confirm with the
/// master password + acknowledge the lockout risk → key written + vault
/// re-wrapped → offer a backup export.
struct DeviceKeySetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var volumes: [RemovableVolume] = []
    @State private var selectedVolumeID: RemovableVolume.ID?
    @State private var password = ""
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var completedDeviceKey: Data?

    private var selectedVolume: RemovableVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    var body: some View {
        VStack(spacing: 16) {
            if let completedDeviceKey {
                completed(deviceKey: completedDeviceKey)
            } else {
                setup
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: refreshVolumes)
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Label("Require a USB Security Key", systemImage: "mediastick")
                .font(.title3.bold())
            Text("SafeKey writes a random key file to the device you choose. From then on, unlocking needs your password AND that device — cryptographically, not as a removable check.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                if volumes.isEmpty {
                    VStack(spacing: 6) {
                        Text("No external volumes found.")
                            .foregroundStyle(.secondary)
                        Button("Rescan") { refreshVolumes() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 2) {
                        ForEach(volumes) { volume in
                            Button {
                                selectedVolumeID = volume.id
                            } label: {
                                HStack {
                                    Image(systemName: volume.isRemovable ? "mediastick" : "externaldrive.fill")
                                    VStack(alignment: .leading) {
                                        Text(volume.name)
                                        Text(volume.url.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedVolumeID == volume.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(6)
                            }
                            .buttonStyle(.plain)
                            .background(
                                selectedVolumeID == volume.id ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                    }
                }
            }

            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $acknowledged) {
                Text("I understand: if I lose this device and its backup, the vault is permanently unrecoverable. There is no override.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    enable()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).frame(minWidth: 90)
                    } else {
                        Text("Require Key").frame(minWidth: 90)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(selectedVolume == nil || password.isEmpty || !acknowledged || isWorking)
            }
        }
    }

    private func completed(deviceKey: Data) -> some View {
        VStack(spacing: 14) {
            Label("Security Key Active", systemImage: "checkmark.seal.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)
            Text("The key file was written to “\(selectedVolume?.name ?? "the device")”. Store a backup copy somewhere safe (another stick, printed, or in a safe) — it is the only recovery path.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export Backup Key…") { exportBackup(deviceKey) }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func refreshVolumes() {
        volumes = model.deviceKeyProvider.candidateVolumes()
        if let first = volumes.first, selectedVolumeID == nil {
            selectedVolumeID = first.id
        }
    }

    private func enable() {
        guard let volume = selectedVolume else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                completedDeviceKey = try await model.enableDeviceFactor(password: password, volume: volume)
            } catch VaultError.wrongPassword {
                errorMessage = "Wrong master password."
            } catch {
                errorMessage = "Could not enable the security key: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func exportBackup(_ deviceKey: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "safekey-device-backup.key"
        panel.title = "Export Backup Key"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try deviceKey.write(to: url, options: [.atomic])
            // This file is the second factor — not world-readable.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Silently "succeeding" here would leave the user believing they
            // have a backup of an unrecoverable key.
            errorMessage = "Could not write the backup key: \(error.localizedDescription)"
        }
    }
}

/// Disable flow — needs password and the stick present.
struct DeviceKeyDisableView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            Label("Remove Security Key Requirement", systemImage: "mediastick")
                .font(.title3.bold())
            Text("The vault will unlock with the password alone again. The key file is removed from the device. Keep the device inserted to confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    disable()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small).frame(minWidth: 90)
                    } else {
                        Text("Remove").frame(minWidth: 90)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(password.isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func disable() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.disableDeviceFactor(password: password)
                dismiss()
            } catch VaultError.wrongPassword {
                errorMessage = "Wrong master password."
                isWorking = false
            } catch VaultError.deviceKeyRequired {
                errorMessage = "Insert the security key first — removing the requirement needs it present."
                isWorking = false
            } catch {
                errorMessage = "Could not remove the requirement: \(error.localizedDescription)"
                isWorking = false
            }
        }
    }
}
