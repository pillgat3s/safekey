import SwiftUI

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                TabView {
                    Tab("General", systemImage: "gear") {
                        GeneralSettingsView(session: session)
                    }
                    Tab("Security", systemImage: "lock.fill") {
                        SecuritySettingsView(session: session)
                    }
                    Tab("Self-Destruct", systemImage: "flame.fill") {
                        SelfDestructSettingsView(session: session)
                    }
                    Tab("Disguise", systemImage: "theatermasks.fill") {
                        DisguiseSettingsView()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Vault Is Locked", systemImage: "lock.fill")
                } description: {
                    Text("Unlock SafeKey to change settings.")
                }
                .frame(width: 480, height: 260)
            }
        }
        .protectedWindow(
            blocksScreenCapture: model.session?.settings.effectiveBlockScreenCapture ?? true
        )
    }
}
