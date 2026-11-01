import XCTest
import CryptoKit
@testable import SafeKeyCore

/// Shared groups, driven the way the apps drive them: two iCloud accounts,
/// each with its own vault and its own master password, one group between
/// them. Nothing here calls the merge engine directly — every change travels
/// because a session reported it and a coordinator ran.
@MainActor
final class SharedGroupSyncTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeySharedGroupTests-\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: SyncCoordinator.discoveryPendingKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: SyncCoordinator.discoveryPendingKey)
    }

    /// One person's device: their account, their vault, their coordinator.
    @MainActor
    private struct Device {
        let account: String
        let session: VaultSession
        let coordinator: SyncCoordinator
        /// The account's own vault zone.
        let privateZone: CloudServer
        let connection: OnlineSwitch

        @discardableResult
        func sync() async -> VaultSync.Outcome? {
            await coordinator.syncIfEnabled(session: session)
        }

        var names: Set<String> { Set(session.entries.map(\.name)) }
        func names(inGroup id: UUID) -> Set<String> {
            Set(session.entries.filter { $0.groupID == id }.map(\.name))
        }
    }

    private func entry(_ name: String, secret: String = "0xabc") -> WalletEntry {
        WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: secret)
    }

    private func makeVault(entries: [WalletEntry], syncEnabled: Bool, password: String) throws -> Vault.Unlocked {
        var payload = VaultPayload(entries: entries)
        payload.settings.cloudSyncEnabled = syncEnabled
        return try Vault.create(password: password, payload: payload, iterations: 1_000).1
    }

    /// A device for one account. Two devices on the same account share the
    /// account's private zone and are handed the same vault.
    private func makeDevice(
        account: String,
        cloud: FakeCloud,
        privateZone: CloudServer = CloudServer(),
        entries: [WalletEntry] = [],
        syncEnabled: Bool = true,
        vault: Vault.Unlocked? = nil,
        name: String? = nil
    ) throws -> Device {
        let unlocked = try vault ?? makeVault(entries: entries, syncEnabled: syncEnabled, password: "\(account)-password-1")
        let connection = OnlineSwitch()
        let environment = SyncCoordinator.Environment(
            isAvailable: { true },
            makeBackend: { _ in DeviceBackend(server: privateZone) },
            sharing: FakeSharedGroupService(cloud: cloud, account: account, connection: connection),
            editDebounce: .milliseconds(20)
        )
        let store = VaultStore(directory: directory.appendingPathComponent(name ?? account, isDirectory: true))
        let coordinator = SyncCoordinator(store: store, environment: environment)
        let session = VaultSession(unlocked: unlocked, store: store)
        coordinator.attach(to: session)
        return Device(account: account, session: session, coordinator: coordinator, privateZone: privateZone, connection: connection)
    }

    /// The owner makes a group and puts a wallet in it; the member is
    /// invited, accepts, and syncs. The starting point of most tests below.
    private func groupOf(owner: Device, member: Device, cloud: FakeCloud, wallet: String = "Team hot wallet") async throws -> WalletGroup {
        let group = try await owner.coordinator.createSharedGroup(name: "Team", session: owner.session)
        let entry = try XCTUnwrap(owner.session.entries.first { $0.name == wallet })
        owner.session.move(entryID: entry.id, toGroup: group.id)
        await owner.sync()

        await cloud.invite(member.account, to: group.id)
        try await cloud.accept(member.account, groupID: group.id)
        member.coordinator.requestDiscovery()
        await member.sync()
        return group
    }

    // MARK: - Creating and filling a group

    func testCreatingAGroupMakesItsZoneBeforeItIsInTheVault() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud)

        let group = try await owner.coordinator.createSharedGroup(name: "Team", session: owner.session)

        let zones = await cloud.groupIDs
        XCTAssertEqual(zones, [group.id], "the zone has to exist for the wallets to have somewhere to go")
        XCTAssertEqual(owner.session.sharedGroups.map(\.name), ["Team"])
        XCTAssertEqual(owner.session.membership(for: group.id)?.isOwner, true)
        XCTAssertTrue(owner.session.groups.isEmpty, "a shared group is not one of the vault's own folders")
        let name = await cloud.name(of: group.id)
        XCTAssertEqual(name, "Team", "the invitation carries the name")
    }

    func testCreatingAGroupNeedsICloud() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud)
        await owner.connection.set(online: false)

        do {
            _ = try await owner.coordinator.createSharedGroup(name: "Team", session: owner.session)
            XCTFail("a group with no zone would have nowhere to put its wallets")
        } catch {
            XCTAssertTrue(owner.session.sharedGroups.isEmpty, "nothing may be left behind in the vault")
            XCTAssertTrue(owner.session.memberships.isEmpty)
        }
    }

    /// Moving a wallet into a shared group takes it out of the vault's own
    /// zone and puts it in the group's. Leaving it in both would hand the
    /// private copy back to the owner's other devices as a second wallet.
    func testMovingAWalletInChangesItsZone() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet"), entry("Mine")])
        await owner.sync()
        var live = await owner.privateZone.liveRecordIDs
        XCTAssertEqual(live.count, 2)

        let group = try await owner.coordinator.createSharedGroup(name: "Team", session: owner.session)
        let moved = try XCTUnwrap(owner.session.entries.first { $0.name == "Team hot wallet" })
        owner.session.move(entryID: moved.id, toGroup: group.id)
        await owner.sync()

        live = await owner.privateZone.liveRecordIDs
        XCTAssertFalse(live.contains(moved.id.uuidString), "the private zone must let go of a wallet that is now shared")
        XCTAssertEqual(live.count, 1, "the other wallet stays")
        let zoneOrNil = await cloud.server(for: group.id)
        let zone = try XCTUnwrap(zoneOrNil)
        let shared = await zone.liveRecordIDs
        XCTAssertEqual(shared, [moved.id.uuidString, "group:" + group.id.uuidString], "the wallet and the group record")

        // Sealed under the group's key, not the vault's.
        let recordOrNil = await zone.record(for: moved.id.uuidString)
        let record = try XCTUnwrap(recordOrNil)
        XCTAssertNil(try? VaultSync.open(record.payload, id: moved.id.uuidString, dek: owner.session.dek), "the vault key must not open a shared record")
        let key = try XCTUnwrap(owner.session.membership(for: group.id)).symmetricKey
        let opened = try VaultSync.open(record.payload, id: moved.id.uuidString, dek: key)
        XCTAssertEqual(opened.secret, "0xabc")
    }

    // MARK: - A member joining

    func testAnInvitedMemberReceivesTheGroupAndItsWallets() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet", secret: "0xteam"), entry("Mine")])
        let member = try makeDevice(account: "member", cloud: cloud, entries: [entry("Member's own")])

        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        XCTAssertEqual(member.session.sharedGroups.map(\.name), ["Team"], "the group arrives with its name")
        XCTAssertEqual(member.session.membership(for: group.id)?.isOwner, false)
        XCTAssertEqual(member.names(inGroup: group.id), ["Team hot wallet"])
        XCTAssertEqual(member.session.entries.first { $0.name == "Team hot wallet" }?.secret, "0xteam", "the secret has to survive the trip")
        XCTAssertEqual(member.names, ["Member's own", "Team hot wallet"], "and nothing else of the owner's comes along")
        let memberPrivate = await member.privateZone.liveRecordIDs
        XCTAssertEqual(memberPrivate.count, 1, "the shared wallet must not be copied into the member's own zone")
    }

    /// Someone who was not invited sees nothing, however the zone is named.
    func testAnUninvitedAccountSeesNothing() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let stranger = try makeDevice(account: "stranger", cloud: cloud)
        _ = try await owner.coordinator.createSharedGroup(name: "Team", session: owner.session)
        await owner.sync()

        stranger.coordinator.requestDiscovery()
        await stranger.sync()

        XCTAssertTrue(stranger.session.sharedGroups.isEmpty)
        XCTAssertTrue(stranger.session.entries.isEmpty)
    }

    /// A member whose own vault does not sync still gets the group: the
    /// group's zone is not the vault's, and the people in it are waiting.
    func testAGroupSyncsEvenWhenTheMembersVaultDoesNot() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud, entries: [entry("Private")], syncEnabled: false)

        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        XCTAssertEqual(member.names(inGroup: group.id), ["Team hot wallet"])
        let memberPrivate = await member.privateZone.liveRecordIDs
        XCTAssertTrue(memberPrivate.isEmpty, "the member's own wallets stay off iCloud, as asked")
        guard case .idle = member.coordinator.status else {
            return XCTFail("expected an idle status, got \(member.coordinator.status)")
        }
    }

    // MARK: - Working together

    func testAMembersEditReachesTheOwner() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        var edited = try XCTUnwrap(member.session.entries.first { $0.name == "Team hot wallet" })
        edited.name = "Team hot wallet (rotated)"
        edited.secret = "0xnew"
        member.session.upsert(edited)
        await member.sync()
        await owner.sync()

        let ownerCopy = try XCTUnwrap(owner.session.entry(id: edited.id))
        XCTAssertEqual(ownerCopy.name, "Team hot wallet (rotated)")
        XCTAssertEqual(ownerCopy.secret, "0xnew")
        XCTAssertEqual(ownerCopy.groupID, group.id, "still in the group")
        XCTAssertEqual(owner.session.entries.count, 1, "an edit must not fork the wallet")
    }

    func testAMemberCanAddAWalletToTheGroup() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        var added = entry("Added by member", secret: "0xmember")
        added.groupID = group.id
        member.session.upsert(added)
        await member.sync()
        await owner.sync()

        XCTAssertEqual(owner.names(inGroup: group.id), ["Team hot wallet", "Added by member"])
        XCTAssertEqual(owner.session.entry(id: added.id)?.secret, "0xmember")
        let memberPrivate = await member.privateZone.liveRecordIDs
        XCTAssertFalse(memberPrivate.contains(added.id.uuidString), "a wallet made in the group goes to the group's zone only")
    }

    func testOwnerRenamingTheGroupReachesTheMember() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        var renamed = try XCTUnwrap(owner.session.group(id: group.id))
        renamed.name = "Ops team"
        owner.session.updateGroup(renamed)
        await owner.sync()
        await member.sync()

        XCTAssertEqual(member.session.group(id: group.id)?.name, "Ops team")
    }

    /// Both edit the same shared wallet before either syncs. Neither version
    /// may be lost — a key one person rotated and the other annotated is two
    /// pieces of real work.
    func testEditingTheSameWalletOnBothSidesKeepsBoth() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        var ownerEdit = try XCTUnwrap(owner.session.entries.first { $0.name == "Team hot wallet" })
        ownerEdit.notes = "owner's note"
        owner.session.upsert(ownerEdit)
        var memberEdit = try XCTUnwrap(member.session.entry(id: ownerEdit.id))
        memberEdit.notes = "member's note"
        member.session.upsert(memberEdit)

        await owner.sync()
        await member.sync()
        await owner.sync()
        await member.sync()

        for device in [owner, member] {
            let notes = Set(device.session.entries.filter { $0.groupID == group.id }.map(\.notes))
            XCTAssertEqual(notes, ["owner's note", "member's note"], "\(device.account) lost a side")
            XCTAssertTrue(device.session.entries.allSatisfy { $0.groupID == group.id }, "the conflicted copy stays in the group")
        }
    }

    // MARK: - Taking wallets out

    /// Moving a wallet out of a shared group takes it away from everyone in
    /// the group — it is not a copy, it is the wallet.
    func testMovingAWalletOutRemovesItForTheOthers() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        let wallet = try XCTUnwrap(member.session.entries.first { $0.name == "Team hot wallet" })
        member.session.move(entryID: wallet.id, toGroup: nil)
        await member.sync()
        await owner.sync()

        XCTAssertTrue(owner.names(inGroup: group.id).isEmpty, "the owner must not keep a wallet the member took out")
        XCTAssertTrue(owner.session.entries.isEmpty)
        XCTAssertEqual(member.names, ["Team hot wallet"], "and the member has it as their own")
        XCTAssertNil(member.session.entries[0].groupID)
        let memberPrivate = await member.privateZone.liveRecordIDs
        XCTAssertEqual(memberPrivate, [wallet.id.uuidString], "it went up to the member's own zone")
        let zoneOrNil = await cloud.server(for: group.id)
        let zone = try XCTUnwrap(zoneOrNil)
        let shared = await zone.liveRecordIDs
        XCTAssertFalse(shared.contains(wallet.id.uuidString), "and left the group's")
    }

    func testDeletingASharedWalletRemovesItForEveryone() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet"), entry("Keep")])
        let member = try makeDevice(account: "member", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        let doomed = try XCTUnwrap(member.session.entries.first { $0.name == "Team hot wallet" })
        member.session.delete(id: doomed.id)
        await member.sync()
        await owner.sync()

        XCTAssertEqual(owner.names, ["Keep"], "the deletion has to reach the owner")
        XCTAssertTrue(owner.names(inGroup: group.id).isEmpty)
        let zoneOrNil = await cloud.server(for: group.id)
        let zone = try XCTUnwrap(zoneOrNil)
        let shared = await zone.liveRecordIDs
        XCTAssertFalse(shared.contains(doomed.id.uuidString))
    }

    // MARK: - The group ending

    /// The owner deleting the group keeps the owner's wallets — they were the
    /// owner's before the group — and takes them away from everyone else.
    func testOwnerDeletingTheGroupKeepsTheWalletsAndDropsTheMembers() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud, entries: [entry("Member's own")])
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)
        XCTAssertEqual(member.names, ["Member's own", "Team hot wallet"])

        owner.session.deleteSharedGroup(id: group.id)
        await owner.sync()

        XCTAssertEqual(owner.names, ["Team hot wallet"])
        XCTAssertNil(owner.session.entries[0].groupID, "back in the owner's own wallets")
        XCTAssertTrue(owner.session.sharedGroups.isEmpty)
        let zones = await cloud.groupIDs
        XCTAssertTrue(zones.isEmpty, "the zone is gone from iCloud")
        let ownerPrivate = await owner.privateZone.liveRecordIDs
        XCTAssertEqual(ownerPrivate.count, 1, "and the wallet went up to the owner's own zone")

        await member.sync()
        XCTAssertEqual(member.names, ["Member's own"], "the member keeps their own wallets and loses the group's")
        XCTAssertTrue(member.session.sharedGroups.isEmpty)
        XCTAssertTrue(member.session.memberships.isEmpty)
    }

    func testAMemberLeavingLosesTheWalletsAndNobodyElseDoes() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud, entries: [entry("Member's own")])
        let other = try makeDevice(account: "other", cloud: cloud)
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)
        await cloud.invite(other.account, to: group.id)
        try await cloud.accept(other.account, groupID: group.id)
        other.coordinator.requestDiscovery()
        await other.sync()
        XCTAssertEqual(other.names, ["Team hot wallet"])

        member.session.leaveSharedGroup(id: group.id)
        await member.sync()

        XCTAssertEqual(member.names, ["Member's own"])
        XCTAssertTrue(member.session.sharedGroups.isEmpty)
        let participants = await cloud.participants(of: group.id)
        XCTAssertEqual(participants, ["other"], "leaving takes the member off the list, nobody else")

        await owner.sync()
        await other.sync()
        XCTAssertEqual(owner.names(inGroup: group.id), ["Team hot wallet"])
        XCTAssertEqual(other.names(inGroup: group.id), ["Team hot wallet"])
    }

    /// The owner taking someone out of the group, which happens in the
    /// system's sharing sheet rather than in the app: the member's next sync
    /// finds the group gone.
    func testARemovedMemberLosesTheGroupOnTheirNextSync() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let member = try makeDevice(account: "member", cloud: cloud, entries: [entry("Member's own")])
        let group = try await groupOf(owner: owner, member: member, cloud: cloud)

        await cloud.removeParticipant(member.account, from: group.id)
        await member.sync()

        XCTAssertEqual(member.names, ["Member's own"])
        XCTAssertTrue(member.session.sharedGroups.isEmpty)
        guard case .idle = member.coordinator.status else {
            return XCTFail("losing a group is not an error, got \(member.coordinator.status)")
        }
        XCTAssertEqual(owner.names(inGroup: group.id), ["Team hot wallet"], "the owner is unaffected")
    }

    /// Deleting a group while offline: the vault lets go of it at once, and
    /// iCloud is told when the device is back — not forgotten, or the next
    /// discovery would find the zone and bring the group straight back.
    func testARemovalMadeOfflineReachesICloudLater() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet")])
        let group = try await owner.coordinator.createSharedGroup(name: "Team", session: owner.session)
        await owner.sync()

        await owner.connection.set(online: false)
        owner.session.deleteSharedGroup(id: group.id)
        await owner.sync()
        var zones = await cloud.groupIDs
        XCTAssertEqual(zones, [group.id], "offline, so iCloud still has it")
        XCTAssertTrue(owner.session.sharedGroups.isEmpty, "the vault does not wait for the network")

        await owner.connection.set(online: true)
        await owner.sync()
        zones = await cloud.groupIDs
        XCTAssertTrue(zones.isEmpty, "the removal was owed and has to be paid")
        XCTAssertTrue(owner.session.sharedGroups.isEmpty, "and discovery must not have brought the group back meanwhile")
    }

    // MARK: - The owner's other devices

    /// The owner's Mac, on the same account, finds the group the phone made
    /// without being invited to anything: the zone is in the account.
    func testTheOwnersOtherDeviceFindsTheGroup() async throws {
        let cloud = FakeCloud()
        let privateZone = CloudServer()
        let vault = try makeVault(entries: [entry("Team hot wallet"), entry("Mine")], syncEnabled: true, password: "owner-password-1")
        let phone = try makeDevice(account: "owner", cloud: cloud, privateZone: privateZone, vault: vault, name: "phone")
        let mac = try makeDevice(account: "owner", cloud: cloud, privateZone: privateZone, vault: vault, name: "mac")
        await phone.sync()
        await mac.sync()

        let group = try await phone.coordinator.createSharedGroup(name: "Team", session: phone.session)
        let moved = try XCTUnwrap(phone.session.entries.first { $0.name == "Team hot wallet" })
        phone.session.move(entryID: moved.id, toGroup: group.id)
        await phone.sync()

        await mac.sync()
        XCTAssertEqual(mac.session.sharedGroups.map(\.name), ["Team"])
        XCTAssertEqual(mac.session.membership(for: group.id)?.isOwner, true, "same account, same standing")
        XCTAssertEqual(mac.names(inGroup: group.id), ["Team hot wallet"])
        XCTAssertEqual(mac.names, ["Team hot wallet", "Mine"], "the moved wallet is in the group, not twice")
        XCTAssertEqual(mac.session.entries.count, 2)
    }

    /// The owner's other device when the group is deleted: the wallets come
    /// back to the vault's own part, as they did on the device that deleted
    /// it, rather than disappearing.
    func testTheOwnersOtherDeviceKeepsTheWalletsWhenTheGroupGoes() async throws {
        let cloud = FakeCloud()
        let privateZone = CloudServer()
        let vault = try makeVault(entries: [entry("Team hot wallet")], syncEnabled: true, password: "owner-password-1")
        let phone = try makeDevice(account: "owner", cloud: cloud, privateZone: privateZone, vault: vault, name: "phone")
        let mac = try makeDevice(account: "owner", cloud: cloud, privateZone: privateZone, vault: vault, name: "mac")
        await phone.sync()
        await mac.sync()
        let group = try await phone.coordinator.createSharedGroup(name: "Team", session: phone.session)
        phone.session.move(entryID: phone.session.entries[0].id, toGroup: group.id)
        await phone.sync()
        await mac.sync()
        XCTAssertEqual(mac.names(inGroup: group.id), ["Team hot wallet"])

        phone.session.deleteSharedGroup(id: group.id)
        await phone.sync()
        await mac.sync()

        XCTAssertEqual(mac.names, ["Team hot wallet"])
        XCTAssertNil(mac.session.entries[0].groupID)
        XCTAssertTrue(mac.session.sharedGroups.isEmpty)
        XCTAssertEqual(mac.session.entries.count, 1, "once, not once from the group and once from the vault")
    }

    // MARK: - Quiet afterwards

    func testNothingMovesOnceEveryoneIsInStep() async throws {
        let cloud = FakeCloud()
        let owner = try makeDevice(account: "owner", cloud: cloud, entries: [entry("Team hot wallet"), entry("Mine")])
        let member = try makeDevice(account: "member", cloud: cloud, entries: [entry("Member's own")])
        _ = try await groupOf(owner: owner, member: member, cloud: cloud)
        await owner.sync()
        await member.sync()

        let ownerQuiet = await owner.sync()
        let memberQuiet = await member.sync()
        XCTAssertEqual(ownerQuiet?.changedLocally, false)
        XCTAssertEqual(ownerQuiet?.pushed, 0)
        XCTAssertEqual(memberQuiet?.changedLocally, false)
        XCTAssertEqual(memberQuiet?.pushed, 0)
    }

    /// Quitting and relaunching between runs: the group's bookkeeping has to
    /// come back from disk, or the next run would hand every record back as
    /// new and push every wallet again.
    func testGroupBookkeepingSurvivesARelaunch() async throws {
        let cloud = FakeCloud()
        let privateZone = CloudServer()
        let vault = try makeVault(entries: [entry("Team hot wallet")], syncEnabled: true, password: "owner-password-1")
        let first = try makeDevice(account: "owner", cloud: cloud, privateZone: privateZone, vault: vault, name: "phone")
        let group = try await first.coordinator.createSharedGroup(name: "Team", session: first.session)
        first.session.move(entryID: first.session.entries[0].id, toGroup: group.id)
        await first.sync()
        await first.session.flushPendingSaves()

        // The same vault file, opened by a new launch.
        let relaunched = try makeDevice(account: "owner", cloud: cloud, privateZone: privateZone, vault: first.session.unlocked, name: "phone")
        let outcome = await relaunched.sync()
        XCTAssertEqual(outcome?.pushed, 0, "nothing changed, so nothing goes up")
        XCTAssertEqual(outcome?.changedLocally, false)
    }
}
