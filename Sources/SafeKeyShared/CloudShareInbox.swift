import Foundation
import CloudKit
import SafeKeyCore

/// Where an accepted invitation lands.
///
/// Tapping an invitation opens the app with the share's metadata, through the
/// app delegate on the Mac and the scene delegate on iOS. Neither has the
/// vault, which may well be locked, so the acceptance is done here — it needs
/// no key, only the account — and the next sync is told to look for the group
/// it joined. The flag lives in the defaults so it survives the app being
/// killed before the vault is next opened.
@MainActor
final class CloudShareInbox {
    static let shared = CloudShareInbox()

    /// Posted once the invitation has been accepted, so an unlocked vault can
    /// sync right away rather than at its next unlock.
    static let accepted = Notification.Name("SafeKey.cloudShareAccepted")
    /// Posted when accepting failed; the message is under `userInfo["message"]`.
    static let failed = Notification.Name("SafeKey.cloudShareFailed")

    private let service = CloudKitSharedGroupService()

    func accept(_ metadata: CKShare.Metadata) {
        Task {
            do {
                try await service.accept(metadata)
                UserDefaults.standard.set(true, forKey: SyncCoordinator.discoveryPendingKey)
                NotificationCenter.default.post(name: Self.accepted, object: nil)
            } catch {
                NotificationCenter.default.post(
                    name: Self.failed,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }
    }
}
