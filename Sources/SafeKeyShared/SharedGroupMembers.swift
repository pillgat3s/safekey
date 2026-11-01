import Foundation
import CloudKit
import SafeKeyCore

/// Who is in a shared group, read from its share.
///
/// The share is the one record in the group's zone that is not sealed: it is
/// CloudKit's own, and the participant list on it is how the owner's device
/// and every member's see the same people. Loaded on demand for the manage
/// screen rather than kept, so it is always what iCloud currently says.
@MainActor
@Observable
final class SharedGroupMembers {
    struct Member: Identifiable, Equatable {
        let id: String
        let name: String
        let isOwner: Bool
        /// Invited, but has not accepted yet.
        let isPending: Bool
        let isMe: Bool
    }

    private(set) var members: [Member] = []
    private(set) var isLoading = false
    private(set) var error: String?

    /// Without a service — the UI-test stand-in — the list is just this
    /// device, which is all that is known.
    func load(membership: SharedGroupMembership, name: String, service: CloudKitSharedGroupService?) async {
        guard let service else {
            members = [Member(id: "me", name: "You", isOwner: membership.isOwner, isPending: false, isMe: true)]
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let share = try await service.share(for: membership, name: name)
            let me = share.currentUserParticipant
            members = share.participants
                .map { participant in
                    Member(
                        id: participant.userIdentity.userRecordID?.recordName ?? UUID().uuidString,
                        name: participant == me ? "You" : Self.displayName(of: participant),
                        isOwner: participant.role == .owner,
                        isPending: participant.acceptanceStatus == .pending,
                        isMe: participant == me
                    )
                }
                .sorted { a, b in
                    if a.isOwner != b.isOwner { return a.isOwner }
                    if a.isMe != b.isMe { return a.isMe }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func displayName(of participant: CKShare.Participant) -> String {
        let identity = participant.userIdentity
        if let components = identity.nameComponents {
            let formatted = PersonNameComponentsFormatter().string(from: components)
            if !formatted.isEmpty { return formatted }
        }
        return identity.lookupInfo?.emailAddress
            ?? identity.lookupInfo?.phoneNumber
            ?? "Invited person"
    }
}
