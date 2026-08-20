import SwiftUI
import SafeKeyCore

@main
struct SafeKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    _ = DebugSupport.renderUnlockSheetIfNeeded(model: model)
                }
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Lock Vault") {
                    model.lock()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.session == nil)
            }
        }

        Settings {
            SettingsRootView()
                .environment(model)
        }
    }
}
