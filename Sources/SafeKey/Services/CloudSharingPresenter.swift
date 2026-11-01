import AppKit
import CloudKit
import SafeKeyCore

/// Puts the system's collaboration sheet up for a shared group: inviting
/// people, seeing who is in, taking someone out, stopping sharing. Apple's
/// sheet rather than ours because it is the only thing that can hand an
/// invitation to another iCloud account.
@MainActor
enum CloudSharingPresenter {
    /// Fetches the group's share and shows the sheet. Errors come back for an
    /// alert rather than being swallowed: a sheet that silently fails to
    /// appear looks like a button doing nothing.
    static func present(
        membership: SharedGroupMembership,
        name: String,
        service: CloudKitSharedGroupService
    ) async throws {
        let share = try await service.share(for: membership, name: name)
        guard let sharing = NSSharingService(named: .cloudSharing) else {
            throw SyncError.unavailable("iCloud sharing is not available on this Mac.")
        }
        let provider = NSItemProvider()
        provider.registerCloudKitShare(share, container: service.container)
        sharing.subject = name
        sharing.perform(withItems: [provider])
    }
}
