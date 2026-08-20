import SwiftUI

struct DisguiseSettingsView: View {
    @State private var manager = DisguiseManager.shared
    @State private var selectedPresetID: String = DisguiseManager.shared.currentPresetID
    @State private var customName: String = DisguiseManager.shared.customName
    @State private var showingRebrandConfirmation = false
    @State private var errorMessage: String?

    private var selectedPreset: DisguisePreset {
        DisguisePreset.preset(id: selectedPresetID) ?? .original
    }

    private var effectiveName: String {
        customName.isEmpty ? selectedPreset.displayName : customName
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(DisguisePreset.all) { preset in
                        Button {
                            selectedPresetID = preset.id
                            if customName == DisguisePreset.preset(id: selectedPresetID)?.displayName {
                                customName = ""
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: DisguiseIconRenderer.image(for: preset, size: 128))
                                    .resizable()
                                    .frame(width: 52, height: 52)
                                Text(preset.displayName)
                                    .font(.caption2)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(selectedPresetID == preset.id ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if selectedPresetID == preset.id {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The icon and name SafeKey shows in the Dock, Finder, and app switcher.")
            }

            Section {
                TextField("Custom name", text: $customName, prompt: Text(selectedPreset.displayName))
                LabeledContent("Preview") {
                    HStack(spacing: 8) {
                        Image(nsImage: DisguiseIconRenderer.image(for: selectedPreset, size: 128))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(effectiveName)
                    }
                }
            }

            Section {
                Button("Apply to Dock Now") {
                    manager.select(presetID: selectedPresetID, customName: customName)
                }
                Button("Rebrand App Bundle…") {
                    showingRebrandConfirmation = true
                }
                .disabled(!manager.bundleIsWritable)
                if manager.currentPresetID != DisguisePreset.original.id || !manager.customName.isEmpty {
                    Button("Revert to SafeKey", role: .destructive) {
                        selectedPresetID = DisguisePreset.original.id
                        customName = ""
                        manager.select(presetID: DisguisePreset.original.id, customName: "")
                    }
                }
            } header: {
                Text("Apply")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“Apply to Dock Now” changes the running app immediately and is remembered at launch.")
                    Text("“Rebrand App Bundle” also rewrites the app's name and icon on disk so Finder and Spotlight show the disguise. SafeKey re-signs itself and relaunches; your vault is untouched.")
                    if !manager.bundleIsWritable {
                        Text("Rebranding is unavailable because this copy of SafeKey isn't writable — move it to /Applications or your home folder.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .alert("Rebrand SafeKey?", isPresented: $showingRebrandConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Rebrand & Relaunch") { rebrand() }
        } message: {
            Text("SafeKey will appear as “\(effectiveName)” everywhere, re-sign itself, and relaunch. You can revert any time from this screen.")
        }
        .alert("Rebrand Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func rebrand() {
        do {
            try manager.rebrandBundle(preset: selectedPreset, customName: customName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
