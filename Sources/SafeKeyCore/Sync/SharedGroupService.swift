import Foundation

/// The part of iCloud that holds shared groups, behind a protocol so the
/// coordinator can be driven by a stand-in in tests.
///
/// A shared group is one zone in its owner's private database, shared with
/// its members. Members reach it through their shared database; the owner's
/// other devices find it in the private one. Each zone holds the group's
/// wallets and the group record itself, sealed under the group key, and a
/// root record carrying that key in a field CloudKit encrypts end to end for
/// the people the zone is shared with.
public protocol SharedGroupService: Sendable {
    /// Creates the group's zone with its key, shared with nobody yet. The
    /// name goes on the invitation; everything else about the group travels
    /// sealed.
    func create(_ membership: SharedGroupMembership, name: String) async throws
    /// Every shared group this account can reach, with its key: the groups
    /// it owns and the ones it has accepted an invitation to. A group that
    /// used to be here and is not any more was deleted by its owner, or this
    /// account was removed from it.
    func discover() async throws -> [SharedGroupMembership]
    /// The store for one group's records.
    func makeBackend(for membership: SharedGroupMembership) -> any SyncBackend
    /// For the owner: deletes the group from iCloud for everyone. For a
    /// member: leaves it. The key is not needed for either, so a removal
    /// that is being retried later can be kept without it.
    func remove(_ membership: SharedGroupMembership) async throws
}
