import SwiftUI
import CloudKit
import UIKit
import SafeKeyCore

/// The system's sharing sheet for a group: inviting people by Messages or
/// Mail, seeing who is in, taking someone out, stopping sharing. Apple's,
/// not ours, because it is the only thing that can hand an invitation to
/// another iCloud account.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let title: String
    /// Called when the sheet reports a failure to save the share.
    var onError: ((String) -> Void)?

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // Everyone in a group can edit its wallets, and only invited people
        // may join: the sheet is not to offer a read-only or a public link.
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {
        context.coordinator.title = title
        context.coordinator.onError = onError
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(title: title, onError: onError)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        var title: String
        var onError: ((String) -> Void)?

        init(title: String, onError: ((String) -> Void)?) {
            self.title = title
            self.onError = onError
        }

        func cloudSharingController(_ controller: UICloudSharingController, failedToSaveShareWithError error: any Error) {
            onError?(error.localizedDescription)
        }

        func itemTitle(for controller: UICloudSharingController) -> String? { title }

        func itemType(for controller: UICloudSharingController) -> String? { "com.andri.safekey.sharedgroup" }

        func itemThumbnailData(for controller: UICloudSharingController) -> Data? {
            UIImage(named: "AppIcon")?.pngData()
        }
    }
}

/// Fetches a group's share and puts the sharing sheet up, with a spinner
/// while the share is on its way. One view so every "Add People" button in
/// the app behaves the same.
struct SharedGroupInviteSheet: View {
    let session: VaultSession
    let group: WalletGroup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var share: CKShare?
    @State private var failure: String?

    var body: some View {
        Group {
            if let share, let service = model.cloudSharing {
                CloudSharingView(share: share, container: service.container, title: group.name) { message in
                    failure = message
                }
                .ignoresSafeArea()
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't Open Sharing", systemImage: "person.2.slash")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Done") { dismiss() }
                }
            } else {
                ProgressView("Preparing invitation…")
            }
        }
        .task {
            guard let membership = session.membership(for: group.id) else {
                failure = "This group is no longer shared."
                return
            }
            guard let service = model.cloudSharing else {
                failure = "Inviting people needs iCloud, which this build is running without."
                return
            }
            do {
                share = try await service.share(for: membership, name: group.name)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
