import XCTest
import CryptoKit
@testable import SafeKeyCore

/// Two devices, one iCloud account — the case the whole feature exists for.
final class TwoDeviceSyncTests: XCTestCase {
    private let dek = SymmetricKey(size: .bits256)

    private func entry(_ name: String, secret: String = "0xabc") -> WalletEntry {
        WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: secret)
    }

    /// Later than any date the test has produced so far, so "edited after the
    /// last sync" is unambiguous without sleeping.
    private func later(_ seconds: TimeInterval = 60) -> Date {
        Date().addingTimeInterval(seconds)
    }

    // MARK: - The everyday path

    func testWalletAddedOnOneDeviceArrivesOnTheOther() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Cold Storage")]))
        var phone = Device(server: server, dek: dek)

        try await mac.syncNow()
        try await phone.syncNow()

        XCTAssertEqual(phone.names, ["Cold Storage"])
        XCTAssertEqual(phone.payload.entries.first?.secret, "0xabc", "the secret has to survive the round trip")
    }

    func testEditOnOneDeviceUpdatesTheOther() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Trading")]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()

        mac.payload.entries[0].name = "Trading (renamed)"
        mac.payload.entries[0].modifiedAt = later()
        try await mac.syncNow()
        try await phone.syncNow()

        XCTAssertEqual(phone.names, ["Trading (renamed)"])
        XCTAssertEqual(phone.payload.entries.count, 1, "a rename must not fork the wallet in two")
    }

    /// The other half of every sync feature, and the half that is easy to get
    /// wrong: a delete that does not travel leaves the wallet on the other
    /// device for ever.
    func testDeletedWalletDisappearsFromTheOtherDevice() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Burner"), entry("Keep")]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()
        XCTAssertEqual(phone.names, ["Burner", "Keep"])

        let burner = try XCTUnwrap(mac.payload.entries.first { $0.name == "Burner" })
        mac.payload.entries.removeAll { $0.id == burner.id }
        mac.state.noteDeletion(walletID: burner.id)
        try await mac.syncNow()

        try await phone.syncNow()
        XCTAssertEqual(phone.names, ["Keep"])
        let remaining = await server.liveRecordIDs
        XCTAssertFalse(remaining.contains(burner.id.uuidString), "the record has to be gone from iCloud too")
    }

    /// A device that joins after the deletion must not resurrect it — the
    /// deletion has to have removed the record, not merely been announced.
    func testDeletedWalletStaysGoneForADeviceJoiningLater() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Burner"), entry("Keep")]))
        try await mac.syncNow()

        let burner = try XCTUnwrap(mac.payload.entries.first { $0.name == "Burner" })
        mac.payload.entries.removeAll { $0.id == burner.id }
        mac.state.noteDeletion(walletID: burner.id)
        try await mac.syncNow()

        var newPhone = Device(server: server, dek: dek)
        try await newPhone.syncNow()
        XCTAssertEqual(newPhone.names, ["Keep"])
    }

    /// Deleting and immediately quitting is ordinary use, not an edge case.
    func testDeletionSurvivesQuittingBeforeItReachedTheServer() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Burner")]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()

        let burner = try XCTUnwrap(mac.payload.entries.first)
        mac.payload.entries.removeAll()
        mac.state.noteDeletion(walletID: burner.id)
        // Quit here: nothing was pushed, the note only exists in the file.
        try mac.relaunch()
        XCTAssertEqual(mac.state.pendingDeletions, [burner.id.uuidString])

        try await mac.syncNow()
        try await phone.syncNow()
        XCTAssertTrue(phone.payload.entries.isEmpty, "the deletion has to outlive the app that made it")
    }

    /// A wallet deleted here must not be pushed back up by the same run.
    func testDeletedWalletIsNotImmediatelyRepushed() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Burner")]))
        try await mac.syncNow()

        let burner = try XCTUnwrap(mac.payload.entries.first)
        mac.payload.entries.removeAll()
        mac.state.noteDeletion(walletID: burner.id)
        try await mac.syncNow()
        try await mac.syncNow()

        let live = await server.liveRecordIDs
        XCTAssertTrue(live.isEmpty, "iCloud still holds a wallet that was deleted twice over")
    }

    /// Vault dates have whole-second precision, so a rename made just after a
    /// sync carries the *same* timestamp as the version already sent. Nothing
    /// about that is exotic — it is what happens when you fix a typo.
    func testAnEditInTheSameSecondAsTheLastSyncStillTravels() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Tradng")]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()

        let stamp = mac.payload.entries[0].modifiedAt
        mac.payload.entries[0].name = "Trading"
        XCTAssertEqual(mac.payload.entries[0].modifiedAt, stamp, "the clock has not moved on")

        try await mac.syncNow()
        try await phone.syncNow()
        XCTAssertEqual(phone.names, ["Trading"])
    }

    /// And when both devices edit inside the same second, the timestamps are
    /// identical too — which must not be read as "the same version".
    func testEditsInTheSameSecondOnBothDevicesKeepBothCopies() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Wallet", secret: "original")]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()

        mac.payload.entries[0].secret = "mac edit"
        phone.payload.entries[0].secret = "phone edit"
        XCTAssertEqual(mac.payload.entries[0].modifiedAt, phone.payload.entries[0].modifiedAt)

        try await mac.syncNow()
        let outcome = try await phone.syncNow()

        XCTAssertEqual(outcome.conflicts, 1)
        XCTAssertEqual(Set(phone.payload.entries.map(\.secret)), ["mac edit", "phone edit"])
    }

    /// Bookkeeping written by an older build has dates where digests now go.
    /// It has to keep meaning "the store holds these", or every record would
    /// arrive as new — including ones deleted here before the upgrade.
    func testBookkeepingFromAnOlderBuildStillCounts() throws {
        let id = UUID().uuidString
        // Dates as the state file actually holds them: a plain JSONEncoder,
        // so seconds since the reference date rather than an ISO string.
        let legacy = #"{"syncedAt":{"ID":757382400},"token":"AQ=="}"#
            .replacingOccurrences(of: "ID", with: id)
        let state = try JSONDecoder().decode(VaultSync.State.self, from: Data(legacy.utf8))

        XCTAssertNotNil(state.agreed[id], "the store is still known to hold this record")
        XCTAssertNotEqual(state.agreed[id], VaultSync.version(of: entry("anything")))
        XCTAssertTrue(state.pendingDeletions.isEmpty)
        XCTAssertNotNil(state.token)
    }

    // MARK: - Groups

    func testGroupRenameReachesTheOtherDevice() async throws {
        let server = CloudServer()
        let group = WalletGroup(name: "Savings", chain: .evm)
        var mac = Device(server: server, dek: dek, payload: VaultPayload(groups: [group]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()
        XCTAssertEqual(phone.groupNames, ["Savings"])

        mac.payload.groups[0].name = "Long term"
        mac.payload.groups[0].modifiedAt = later()
        try await mac.syncNow()
        try await phone.syncNow()

        XCTAssertEqual(phone.groupNames, ["Long term"])
        XCTAssertEqual(phone.payload.groups.count, 1)
    }

    /// Deleting a folder must never delete what is inside it.
    func testDeletedGroupUngroupsItsWalletsOnTheOtherDevice() async throws {
        let server = CloudServer()
        let group = WalletGroup(name: "Savings", chain: .evm)
        var member = entry("Ledger")
        member.groupID = group.id

        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [member], groups: [group]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()
        XCTAssertEqual(phone.payload.entries.first?.groupID, group.id)

        mac.payload.groups.removeAll { $0.id == group.id }
        for index in mac.payload.entries.indices where mac.payload.entries[index].groupID == group.id {
            mac.payload.entries[index].groupID = nil
        }
        mac.state.noteDeletion(groupID: group.id)
        try await mac.syncNow()
        try await phone.syncNow()

        XCTAssertTrue(phone.payload.groups.isEmpty, "the group has to go")
        XCTAssertEqual(phone.payload.entries.count, 1, "its wallet has to stay")
        XCTAssertNil(phone.payload.entries.first?.groupID)
    }

    /// A wallet arriving from another device can name a group this one no
    /// longer has. It must not keep it: a wallet holding an id that is not in
    /// the vault shows up neither in that group nor in the ungrouped list, so
    /// it falls out of the way the vault is browsed while still being in it.
    ///
    /// The case that sticks is a conflicted copy, because that is a brand-new
    /// record — no other device will ever correct it.
    func testAnArrivingWalletNeverKeepsAGroupThisDeviceDoesNotHave() async throws {
        let server = CloudServer()
        var phone = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Ledger")]))
        try await phone.syncNow()

        // The other device still holds a group this one deleted long ago, and
        // pushes the wallet still filed under it.
        var theirs = phone.payload.entries[0]
        theirs.groupID = UUID()
        theirs.secret = "edited there"
        theirs.modifiedAt = later()
        await server.save([SyncRecord(
            id: theirs.id.uuidString,
            payload: try VaultSync.seal(theirs, dek: dek),
            modifiedAt: theirs.modifiedAt
        )])

        // Edited here as well, so the arrival is kept alongside as a copy.
        phone.payload.entries[0].secret = "edited here"
        phone.payload.entries[0].modifiedAt = later(30)

        let outcome = try await phone.syncNow()

        XCTAssertEqual(outcome.conflicts, 1)
        XCTAssertEqual(phone.payload.entries.count, 2)
        for entry in phone.payload.entries {
            XCTAssertNil(entry.groupID, "\(entry.name) is filed under a group that is not in the vault")
        }
    }

    /// Both devices rename the same group, and the vault's dates are whole
    /// seconds, so the two versions carry the same timestamp. "Newer wins"
    /// cannot separate them — each device would keep its own, push it, and be
    /// handed the other's back, for ever.
    func testGroupsRenamedInTheSameSecondOnBothDevicesSettle() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(groups: [WalletGroup(name: "Savings", chain: .evm)]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()

        mac.payload.groups[0].name = "Long term"
        phone.payload.groups[0].name = "Cold"
        XCTAssertEqual(
            mac.payload.groups[0].modifiedAt,
            phone.payload.groups[0].modifiedAt,
            "the point of the test is that the clocks agree"
        )

        for _ in 0..<3 {
            try await mac.syncNow()
            try await phone.syncNow()
        }

        XCTAssertEqual(
            mac.payload.groups.map(\.name),
            phone.payload.groups.map(\.name),
            "the two devices are still disagreeing about the name"
        )
        let settledMac = try await mac.syncNow()
        let settledPhone = try await phone.syncNow()
        XCTAssertEqual(settledMac.pushed, 0, "the Mac is still rewriting the group on every sync")
        XCTAssertEqual(settledPhone.pushed, 0, "the phone is still rewriting the group on every sync")
        XCTAssertFalse(settledMac.changedLocally)
        XCTAssertFalse(settledPhone.changedLocally)
    }

    // MARK: - Conflicts

    /// Both sides edited since the last sync. Neither version may be dropped.
    func testEditsOnBothDevicesKeepBothCopies() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Wallet", secret: "original")]))
        var phone = Device(server: server, dek: dek)
        try await mac.syncNow()
        try await phone.syncNow()

        mac.payload.entries[0].secret = "mac edit"
        mac.payload.entries[0].modifiedAt = later(30)
        phone.payload.entries[0].secret = "phone edit"
        phone.payload.entries[0].modifiedAt = later(60)

        try await mac.syncNow()      // mac's version reaches the server first
        let outcome = try await phone.syncNow()

        XCTAssertEqual(outcome.conflicts, 1)
        XCTAssertEqual(phone.payload.entries.count, 2)
        XCTAssertEqual(Set(phone.payload.entries.map(\.secret)), ["mac edit", "phone edit"])
        XCTAssertTrue(phone.names.contains { $0.hasSuffix("(conflicted copy)") })

        // And the kept copy travels, so the choice is available on both.
        try await phone.syncNow()
        try await mac.syncNow()
        XCTAssertEqual(mac.payload.entries.count, 2)
    }

    // MARK: - Quiet runs

    /// A sync with nothing to do must not report changes: every reported change
    /// rewrites the vault file, and the "different vault" check reads it too.
    func testSecondSyncWithNothingToDoIsSilent() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(
            entries: [entry("One"), entry("Two")],
            groups: [WalletGroup(name: "Savings", chain: .evm)]
        ))
        try await mac.syncNow()

        let second = try await mac.syncNow()
        XCTAssertEqual(second.pushed, 0)
        XCTAssertEqual(second.pulled, 0, "the device's own records came back and were treated as new")
        XCTAssertFalse(second.changedLocally)

        let third = try await mac.syncNow()
        XCTAssertFalse(third.changedLocally)
    }

    // MARK: - Edits made while a sync is in flight

    /// The reason a run is three steps. A fetch takes seconds on a phone, and
    /// the user is looking at the app the whole time.
    func testWalletAddedWhileTheFetchWasInFlightIsNotLost() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Existing")]))
        try await mac.syncNow()

        var phone = Device(server: server, dek: dek)
        let pulled = try await phone.sync.pull(state: &phone.state)

        // The user adds a wallet while the fetch is on the wire.
        phone.payload.entries.append(entry("Added mid-sync"))

        phone.sync.merge(pulled, into: &phone.payload, state: &phone.state)
        let toPush = try phone.sync.pendingPushes(payload: phone.payload, state: phone.state)
        try await phone.sync.push(toPush, state: &phone.state)

        XCTAssertEqual(phone.names, ["Existing", "Added mid-sync"])
        var mac2 = mac
        try await mac2.syncNow()
        XCTAssertTrue(mac2.names.contains("Added mid-sync"), "and it has to reach the other device")
    }

    // MARK: - The vault record

    /// Publishing over another vault's header would strand its records for
    /// good: they are sealed under a key only that header carries.
    func testHeaderOfADifferentVaultIsNeverOverwritten() async throws {
        let server = CloudServer()
        let (_, mine) = try Vault.create(password: "correct-horse-1", iterations: 1_000)
        let (_, theirs) = try Vault.create(password: "different-pass-2", iterations: 1_000)

        try await VaultSync(backend: DeviceBackend(server: server), dek: theirs.dek)
            .publishVault(header: theirs.header)

        do {
            try await VaultSync(backend: DeviceBackend(server: server), dek: mine.dek)
                .publishVault(header: mine.header)
            XCTFail("publishing over a different vault must be refused")
        } catch let error as SyncError {
            XCTAssertEqual(error, .differentVault(remote: theirs.header.vaultID, local: mine.header.vaultID))
        }

        let stored = await server.fetchVault()
        XCTAssertEqual(stored?.vaultID, theirs.header.vaultID, "the first vault's header must still be there")
    }

    /// Publishing the same vault again is the normal case and must be allowed.
    func testPublishingTheSameVaultAgainIsFine() async throws {
        let server = CloudServer()
        let (_, vault) = try Vault.create(password: "correct-horse-1", iterations: 1_000)
        let sync = VaultSync(backend: DeviceBackend(server: server), dek: vault.dek)

        try await sync.publishVault(header: vault.header)
        try await sync.publishVault(header: vault.header)

        let stored = await server.fetchVault()
        XCTAssertEqual(stored?.vaultID, vault.header.vaultID)
    }

    // MARK: - Joining

    /// The whole point of publishing the header: a second device joins with
    /// the master password and nothing else.
    func testSecondDeviceJoinsWithThePasswordAndSeesEverything() async throws {
        let server = CloudServer()
        let password = "correct-horse-battery-3"
        let (_, vault) = try Vault.create(password: password, iterations: 1_000)

        let group = WalletGroup(name: "Savings", chain: .evm)
        var member = entry("Ledger", secret: "seed words here")
        member.groupID = group.id
        var mac = Device(server: server, dek: vault.dek, payload: VaultPayload(entries: [member], groups: [group]))
        try await mac.sync.publishVault(header: vault.header)
        try await mac.syncNow()

        let joined = try await VaultSync.adoptRemoteVault(
            backend: DeviceBackend(server: server),
            password: password
        )

        XCTAssertEqual(joined.unlocked.header.vaultID, vault.header.vaultID)
        XCTAssertEqual(joined.unlocked.payload.entries.map(\.name), ["Ledger"])
        XCTAssertEqual(joined.unlocked.payload.entries.first?.secret, "seed words here")
        XCTAssertEqual(joined.unlocked.payload.groups.map(\.name), ["Savings"])
        XCTAssertEqual(joined.unlocked.payload.entries.first?.groupID, group.id)

        // And it carries on from there rather than re-pulling everything.
        var phone = Device(server: server, dek: joined.unlocked.dek, payload: joined.unlocked.payload)
        phone.state = joined.state
        let outcome = try await phone.syncNow()
        XCTAssertFalse(outcome.changedLocally)
        XCTAssertEqual(outcome.pushed, 0)
    }

    // MARK: - Recovering from a wiped zone

    /// "Replace the iCloud copy" deletes the zone. The other device is then
    /// holding a token for a zone that no longer exists.
    func testDeviceWithAStaleTokenRecoversWithoutDuplicating() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("One"), entry("Two")]))
        try await mac.syncNow()

        await server.wipeZone()

        let outcome = try await mac.syncNow()
        XCTAssertEqual(outcome.pushed, 2, "everything has to go back up")
        XCTAssertEqual(mac.payload.entries.count, 2, "and nothing may be duplicated locally")
        let live = await server.liveRecordIDs
        XCTAssertEqual(live.count, 2)
    }

    // MARK: - A full day of ordinary use

    /// Both devices, several rounds, ending in agreement. This is the claim the
    /// feature makes, stated once as a test.
    func testBothDevicesConvergeAfterAWeekOfEdits() async throws {
        let server = CloudServer()
        var mac = Device(server: server, dek: dek, payload: VaultPayload(entries: [entry("Cold"), entry("Hot")]))
        var phone = Device(server: server, dek: dek)

        try await mac.syncNow()
        try await phone.syncNow()

        // The phone adds one and renames another.
        phone.payload.entries.append(entry("From the phone"))
        let hotIndex = try XCTUnwrap(phone.payload.entries.firstIndex { $0.name == "Hot" })
        phone.payload.entries[hotIndex].name = "Hot (daily)"
        phone.payload.entries[hotIndex].modifiedAt = later(10)
        try await phone.syncNow()
        try await mac.syncNow()

        // The Mac groups one of them.
        let group = WalletGroup(name: "Savings", chain: .evm)
        mac.payload.groups.append(group)
        let coldIndex = try XCTUnwrap(mac.payload.entries.firstIndex { $0.name == "Cold" })
        mac.payload.entries[coldIndex].groupID = group.id
        mac.payload.entries[coldIndex].modifiedAt = later(20)
        try await mac.syncNow()
        try await phone.syncNow()

        // The phone deletes the one it added.
        let doomed = try XCTUnwrap(phone.payload.entries.first { $0.name == "From the phone" })
        phone.payload.entries.removeAll { $0.id == doomed.id }
        phone.state.noteDeletion(walletID: doomed.id)
        try await phone.syncNow()
        try await mac.syncNow()

        // One more round each so nothing is still in flight.
        try await phone.syncNow()
        try await mac.syncNow()

        XCTAssertEqual(mac.names, ["Cold", "Hot (daily)"])
        XCTAssertEqual(phone.names, mac.names)
        XCTAssertEqual(phone.groupNames, ["Savings"])
        XCTAssertEqual(
            Set(phone.payload.entries.map { "\($0.id)-\($0.groupID?.uuidString ?? "-")" }),
            Set(mac.payload.entries.map { "\($0.id)-\($0.groupID?.uuidString ?? "-")" }),
            "the two devices have to end up holding the same thing"
        )
        let finalMac = try await mac.syncNow()
        let finalPhone = try await phone.syncNow()
        XCTAssertFalse(finalMac.changedLocally)
        XCTAssertFalse(finalPhone.changedLocally)
    }
}
