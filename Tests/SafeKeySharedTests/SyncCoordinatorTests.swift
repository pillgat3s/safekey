import XCTest
import CryptoKit
@testable import SafeKeyCore

/// Lets a test hold a backend call open, so a sync can be caught mid-flight.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened: Bool

    init(opened: Bool = false) { self.opened = opened }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Counts how many runs are inside the backend at once.
actor ConcurrencyProbe {
    private var current = 0
    private(set) var highWaterMark = 0

    func enter() {
        current += 1
        highWaterMark = max(highWaterMark, current)
    }

    func leave() { current -= 1 }
}

/// A backend that pauses inside the fetch, announces that it got there, and
/// records how many runs were inside it at once.
struct GatedBackend: CloudBackend {
    let inner: DeviceBackend
    /// Opened by the test to let the fetch finish.
    let release: Gate
    /// Opened by the backend once a fetch has begun.
    let entered: Gate
    let probe: ConcurrencyProbe

    func fetchChanges(since token: Data?) async throws -> SyncChanges {
        await probe.enter()
        await entered.open()
        await release.wait()
        let changes = try await inner.fetchChanges(since: token)
        await probe.leave()
        return changes
    }

    func save(_ records: [SyncRecord]) async throws { try await inner.save(records) }
    func delete(ids: [String]) async throws { try await inner.delete(ids: ids) }
    func fetchVault() async throws -> SyncedVault? { try await inner.fetchVault() }
    func saveVault(_ vault: SyncedVault) async throws { try await inner.saveVault(vault) }
    var foreignVaultIDs: Set<UUID> { get async { await inner.foreignVaultIDs } }
    func removeEverything() async throws { try await inner.removeEverything() }
}

/// The half of sync that lives in the app: when a run happens, what it merges
/// into, and what it remembers while the network is slow.
@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafeKeySyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Rig {
        let unlocked: Vault.Unlocked
        let session: VaultSession
        let coordinator: SyncCoordinator
        let server: CloudServer
        let release: Gate
        let entered: Gate
        let probe: ConcurrencyProbe
    }

    private func makeVault(
        entries: [WalletEntry],
        syncEnabled: Bool = true,
        password: String = "correct-horse-1"
    ) throws -> Vault.Unlocked {
        var payload = VaultPayload(entries: entries)
        payload.settings.cloudSyncEnabled = syncEnabled
        return try Vault.create(password: password, payload: payload, iterations: 1_000).1
    }

    private func makeRig(
        server: CloudServer = CloudServer(),
        entries: [WalletEntry] = [],
        syncEnabled: Bool = true,
        available: Bool = true,
        gated: Bool = false,
        vault: Vault.Unlocked? = nil,
        directory: URL? = nil
    ) throws -> Rig {
        let unlocked = try vault ?? makeVault(entries: entries, syncEnabled: syncEnabled)
        let directory = directory ?? self.directory!

        // An ungated backend is one whose gate is already open.
        let release = Gate(opened: !gated)
        let entered = Gate()
        let probe = ConcurrencyProbe()

        let environment = SyncCoordinator.Environment(
            isAvailable: { available },
            makeBackend: { _ -> any CloudBackend in
                let direct = DeviceBackend(server: server)
                guard gated else { return direct }
                return GatedBackend(inner: direct, release: release, entered: entered, probe: probe)
            },
            editDebounce: .milliseconds(20)
        )
        let store = VaultStore(directory: directory)
        let coordinator = SyncCoordinator(store: store, environment: environment)
        let session = VaultSession(unlocked: unlocked, store: store)
        coordinator.attach(to: session)
        return Rig(
            unlocked: unlocked,
            session: session,
            coordinator: coordinator,
            server: server,
            release: release,
            entered: entered,
            probe: probe
        )
    }

    private func entry(_ name: String) -> WalletEntry {
        WalletEntry(name: name, chain: .evm, kind: .privateKey, secret: "0xabc")
    }

    // MARK: - Edits made while the network is busy

    /// A fetch takes seconds on a phone and the user is in the app the whole
    /// time. Whatever they do meanwhile has to survive the write-back.
    func testWalletAddedDuringASyncSurvivesIt() async throws {
        let rig = try makeRig(entries: [entry("Existing")], gated: true)
        let run = Task { await rig.coordinator.syncIfEnabled(session: rig.session) }

        await rig.entered.wait()
        rig.session.upsert(entry("Added mid-sync"))
        await rig.release.open()
        _ = await run.value

        XCTAssertEqual(
            Set(rig.session.entries.map(\.name)),
            ["Existing", "Added mid-sync"],
            "the write-back used a payload from before the edit"
        )
    }

    /// Same window, but for a deletion: it is noted on the coordinator while
    /// the run holds its own copy of that bookkeeping.
    func testDeletionMadeDuringASyncStillReachesTheServer() async throws {
        let doomed = entry("Burner")
        let rig = try makeRig(entries: [doomed, entry("Keep")], gated: true)
        let run = Task { await rig.coordinator.syncIfEnabled(session: rig.session) }

        await rig.entered.wait()
        rig.session.delete(id: doomed.id)
        await rig.release.open()
        _ = await run.value

        await rig.coordinator.syncIfEnabled(session: rig.session)
        let live = await rig.server.liveRecordIDs
        XCTAssertFalse(
            live.contains(doomed.id.uuidString),
            "the deletion was dropped when the run wrote its own state back"
        )
    }

    /// Several screens can ask for a sync at once — unlock, an edit, a
    /// deletion. Two runs at a time would both push and the slower one would
    /// write back a merge made against a stale payload.
    func testRunsDoNotOverlap() async throws {
        let rig = try makeRig(entries: [entry("One")], gated: true)
        let first = Task { await rig.coordinator.syncIfEnabled(session: rig.session) }
        let second = Task { await rig.coordinator.syncIfEnabled(session: rig.session) }

        await rig.entered.wait()
        await rig.release.open()
        _ = await first.value
        _ = await second.value

        let overlap = await rig.probe.highWaterMark
        XCTAssertEqual(overlap, 1, "two syncs were inside the backend at once")
    }

    // MARK: - Deletions

    /// Deleting a wallet has to remove it from iCloud, or the other device
    /// restores it and a full fetch brings it back here too.
    func testDeletingAWalletRemovesItFromTheServer() async throws {
        let doomed = entry("Burner")
        let rig = try makeRig(entries: [doomed, entry("Keep")])
        await rig.coordinator.syncIfEnabled(session: rig.session)
        var live = await rig.server.liveRecordIDs
        XCTAssertEqual(live.count, 2)

        rig.session.delete(id: doomed.id)
        await rig.coordinator.syncIfEnabled(session: rig.session)

        live = await rig.server.liveRecordIDs
        XCTAssertFalse(live.contains(doomed.id.uuidString))
        XCTAssertEqual(live.count, 1, "only the wallet that was kept")
    }

    /// Deleting a group removes the folder from iCloud without touching the
    /// wallets that were in it.
    func testDeletingAGroupRemovesOnlyTheGroup() async throws {
        let rig = try makeRig(entries: [entry("Ledger")])
        let group = rig.session.addGroup(name: "Savings", chain: .evm, colorHex: nil)
        rig.session.move(entryID: rig.session.entries[0].id, toGroup: group.id)
        await rig.coordinator.syncIfEnabled(session: rig.session)
        var live = await rig.server.liveRecordIDs
        XCTAssertEqual(live.count, 2, "one wallet and one group")

        rig.session.deleteGroup(id: group.id)
        await rig.coordinator.syncIfEnabled(session: rig.session)

        live = await rig.server.liveRecordIDs
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(rig.session.entries.count, 1, "the wallet stays")
        XCTAssertNil(rig.session.entries[0].groupID)
    }

    /// Quitting between the delete and the next sync is ordinary use. The note
    /// has to be on disk, not just in memory.
    func testADeletionOutlivesTheAppThatMadeIt() async throws {
        let server = CloudServer()
        let doomed = entry("Burner")
        let vault = try makeVault(entries: [doomed])
        let first = try makeRig(server: server, vault: vault)
        await first.coordinator.syncIfEnabled(session: first.session)
        first.session.delete(id: doomed.id)
        // Quit before the note could be sent: the run it asked for never gets
        // to happen, and only what was written down survives.
        first.coordinator.cancelPendingWork()
        await first.session.flushPendingSaves()

        // The same vault, opened again by a new launch of the app.
        var reopened = vault
        reopened.payload.entries.removeAll { $0.id == doomed.id }
        let second = try makeRig(server: server, vault: reopened)
        await second.coordinator.syncIfEnabled(session: second.session)

        let live = await server.liveRecordIDs
        XCTAssertTrue(live.isEmpty, "the deletion did not survive the relaunch")
    }

    // MARK: - Editing without asking

    /// An edit has to travel on its own. Syncing only when the app is opened
    /// would leave a rename sitting on the device that made it.
    func testAnEditAsksForASyncByItself() async throws {
        let rig = try makeRig(entries: [entry("Trading")])
        await rig.coordinator.syncIfEnabled(session: rig.session)

        var edited = rig.session.entries[0]
        edited.name = "Trading (renamed)"
        rig.session.upsert(edited)

        try await waitUntil("the edit reaches the server") {
            let stored = await rig.server.record(for: edited.id.uuidString)
            guard let stored else { return false }
            let opened = try? VaultSync.open(stored.payload, id: edited.id.uuidString, dek: rig.session.dek)
            return opened?.name == "Trading (renamed)"
        }
    }

    // MARK: - Another vault in the account

    /// Publishing over another vault's header would strand its records for
    /// good. The user is told instead.
    func testAForeignVaultIsReportedRatherThanOverwritten() async throws {
        let server = CloudServer()
        let (_, theirs) = try Vault.create(password: "different-pass-2", iterations: 1_000)
        try await VaultSync(backend: DeviceBackend(server: server), dek: theirs.dek)
            .publishVault(header: theirs.header)

        let rig = try makeRig(server: server, entries: [entry("Mine")])
        await rig.coordinator.syncIfEnabled(session: rig.session)

        XCTAssertEqual(rig.coordinator.status, .differentVault)
        let stored = await server.fetchVault()
        XCTAssertEqual(stored?.vaultID, theirs.header.vaultID, "their header must still be there")
        let live = await server.liveRecordIDs
        XCTAssertTrue(live.isEmpty, "and nothing of ours may have been pushed into their vault")
    }

    /// After the user merges the iCloud vault into this one, this vault owns
    /// the copy: its header replaces the old one and its wallets go up.
    func testTakingOverReplacesTheVaultRecord() async throws {
        let server = CloudServer()
        let (_, theirs) = try Vault.create(password: "different-pass-2", iterations: 1_000)
        try await VaultSync(backend: DeviceBackend(server: server), dek: theirs.dek)
            .publishVault(header: theirs.header)

        let rig = try makeRig(server: server, entries: [entry("Mine")])
        await rig.coordinator.takeOverCloudVault(session: rig.session)

        let stored = await server.fetchVault()
        XCTAssertEqual(stored?.vaultID, rig.session.header.vaultID)
        let live = await server.liveRecordIDs
        XCTAssertEqual(live.count, 1)
        guard case .idle = rig.coordinator.status else {
            return XCTFail("expected an idle status, got \(rig.coordinator.status)")
        }
    }

    // MARK: - Two vaults becoming one

    /// The flow a second device actually goes through: it already holds its
    /// own vault, iCloud holds another, and the user merges rather than
    /// choosing which one to lose. Afterwards there is one vault and one
    /// password — the one belonging to the device where the merge was started
    /// — and both devices carry on in step.
    func testMergingTwoVaultsLeavesOneVaultAndBothDevicesInStep() async throws {
        let server = CloudServer()
        let macPassword = "mac-password-1"
        let phonePassword = "phone-password-2"

        // The Mac has been syncing its vault for a while.
        let mac = try makeRig(
            server: server,
            vault: try makeVault(entries: [entry("Mac wallet")], password: macPassword),
            directory: directory.appendingPathComponent("mac", isDirectory: true)
        )
        await mac.coordinator.syncIfEnabled(session: mac.session)

        // The phone has its own, with its own wallets, and finds the account
        // occupied. Nothing of the Mac's may be touched by that discovery.
        var phone = try makeRig(
            server: server,
            vault: try makeVault(entries: [entry("Phone wallet")], password: phonePassword),
            directory: directory.appendingPathComponent("phone", isDirectory: true)
        )
        await phone.coordinator.syncIfEnabled(session: phone.session)
        XCTAssertEqual(phone.coordinator.status, .differentVault)
        let untouched = await server.fetchVault()
        XCTAssertEqual(untouched?.vaultID, mac.session.header.vaultID)

        // The user is shown what merging would add before agreeing to it.
        let (merged, adopted) = try await phone.coordinator.previewCloudMerge(
            password: macPassword,
            into: phone.session.unlocked
        )
        XCTAssertEqual(adopted, 1, "the Mac's wallet is the one that would be taken on")
        XCTAssertEqual(phone.session.entries.count, 1, "previewing must not change anything yet")

        try await phone.session.adopt(merged)
        await phone.coordinator.takeOverCloudVault(session: phone.session)

        XCTAssertEqual(
            Set(phone.session.entries.map(\.name)),
            ["Phone wallet", "Mac wallet"],
            "merging keeps both sides"
        )
        let takenOver = await server.fetchVault()
        XCTAssertEqual(takenOver?.vaultID, phone.session.header.vaultID)

        // The Mac now finds a vault it cannot open — its own password no
        // longer applies — and joins with the phone's.
        await mac.coordinator.syncIfEnabled(session: mac.session)
        XCTAssertEqual(mac.coordinator.status, .differentVault)

        let (rejoined, _) = try await mac.coordinator.fetchCloudVault(password: phonePassword)
        XCTAssertEqual(rejoined.header.vaultID, phone.session.header.vaultID)
        XCTAssertEqual(
            Set(rejoined.payload.entries.map(\.name)),
            ["Phone wallet", "Mac wallet"],
            "the Mac gets both wallets back, under the surviving password"
        )

        // And from there the two are ordinary devices on one vault again.
        let store = VaultStore(directory: directory.appendingPathComponent("mac", isDirectory: true))
        let rejoinedSession = VaultSession(unlocked: rejoined, store: store)
        mac.coordinator.attach(to: rejoinedSession)
        rejoinedSession.upsert(entry("Added after the merge"))
        await mac.coordinator.syncIfEnabled(session: rejoinedSession)
        await phone.coordinator.syncIfEnabled(session: phone.session)

        XCTAssertEqual(
            Set(phone.session.entries.map(\.name)),
            ["Phone wallet", "Mac wallet", "Added after the merge"]
        )
        let quiet = await phone.coordinator.syncIfEnabled(session: phone.session)
        XCTAssertEqual(quiet?.changedLocally, false)
    }

    // MARK: - The two destructive buttons

    /// "Stop Syncing and Remove Copy" takes the vault out of iCloud. What it
    /// must never do is take it off the device the user pressed it on.
    func testRemovingTheCloudCopyLeavesTheVaultOnTheDevice() async throws {
        let rig = try makeRig(entries: [entry("Cold"), entry("Hot")])
        await rig.coordinator.syncIfEnabled(session: rig.session)
        var live = await rig.server.liveRecordIDs
        XCTAssertEqual(live.count, 2)

        await rig.coordinator.removeFromCloud(session: rig.session)

        live = await rig.server.liveRecordIDs
        XCTAssertTrue(live.isEmpty, "the iCloud copy is what was asked for")
        XCTAssertEqual(
            Set(rig.session.entries.map(\.name)),
            ["Cold", "Hot"],
            "the wallets on this device are not what was asked for"
        )
        XCTAssertEqual(rig.coordinator.status, .off)

        // And the bookkeeping is gone, so switching sync back on starts clean
        // rather than believing iCloud still holds what it no longer has.
        let restarted = await rig.coordinator.syncIfEnabled(session: rig.session)
        XCTAssertEqual(restarted?.pushed, 2)
    }

    /// "Replace iCloud Copy with This Vault" is the way out when the account
    /// holds a vault this device cannot open. It has to actually clear the
    /// other one — reporting success while leaving it there looks exactly like
    /// the button doing nothing.
    func testReplacingTheCloudCopyClearsTheVaultThatWasThere() async throws {
        let server = CloudServer()
        let (_, theirs) = try Vault.create(password: "different-pass-2", iterations: 1_000)
        let theirSync = VaultSync(backend: DeviceBackend(server: server), dek: theirs.dek)
        try await theirSync.publishVault(header: theirs.header)
        var theirPayload = VaultPayload(entries: [
            WalletEntry(name: "Not mine", chain: .evm, kind: .privateKey, secret: "theirs")
        ])
        var theirState = VaultSync.State()
        _ = try await theirSync.run(payload: &theirPayload, state: &theirState)

        let rig = try makeRig(server: server, entries: [entry("Mine")])
        await rig.coordinator.syncIfEnabled(session: rig.session)
        XCTAssertEqual(rig.coordinator.status, .differentVault)

        await rig.coordinator.replaceCloudCopy(session: rig.session)

        let vault = await server.fetchVault()
        XCTAssertEqual(vault?.vaultID, rig.session.header.vaultID, "the vault record has to be ours now")
        let live = await server.liveRecordIDs
        XCTAssertEqual(live, [rig.session.entries[0].id.uuidString], "and nothing of theirs may be left")
        XCTAssertEqual(Set(rig.session.entries.map(\.name)), ["Mine"])
        guard case .idle = rig.coordinator.status else {
            return XCTFail("expected an idle status, got \(rig.coordinator.status)")
        }
    }

    // MARK: - Switched off

    func testNothingHappensWhileSyncIsOff() async throws {
        let rig = try makeRig(entries: [entry("Private")], syncEnabled: false)
        await rig.coordinator.syncIfEnabled(session: rig.session)

        XCTAssertEqual(rig.coordinator.status, .off)
        let live = await rig.server.liveRecordIDs
        XCTAssertTrue(live.isEmpty, "sync is off and nothing may leave the device")
    }

    func testASignedOutAccountIsReportedNotRetriedSilently() async throws {
        let rig = try makeRig(entries: [entry("One")], available: false)
        await rig.coordinator.syncIfEnabled(session: rig.session)

        guard case .unavailable = rig.coordinator.status else {
            return XCTFail("expected an unavailable status, got \(rig.coordinator.status)")
        }
    }


    // MARK: - Two devices, driven the way the apps drive them

    /// The whole feature, end to end and through the same code the apps use:
    /// two vault files, two coordinators, one iCloud zone. Nothing here calls
    /// the merge engine directly — each change travels because a session
    /// reported it.
    func testTwoDevicesFollowEachOther() async throws {
        let server = CloudServer()
        let vault = try makeVault(entries: [entry("Cold")])
        let macDirectory = directory.appendingPathComponent("mac", isDirectory: true)
        let phoneDirectory = directory.appendingPathComponent("phone", isDirectory: true)
        let mac = try makeRig(server: server, vault: vault, directory: macDirectory)
        let phone = try makeRig(server: server, vault: vault, directory: phoneDirectory)

        await mac.coordinator.syncIfEnabled(session: mac.session)
        await phone.coordinator.syncIfEnabled(session: phone.session)
        XCTAssertEqual(phone.session.entries.map(\.name), ["Cold"])

        // Adding on the Mac: nobody asks for a sync, the edit does.
        mac.session.upsert(entry("Hot"))
        try await waitUntil("the new wallet reaches iCloud") {
            await server.liveRecordIDs.count == 2
        }
        await phone.coordinator.syncIfEnabled(session: phone.session)
        XCTAssertEqual(Set(phone.session.entries.map(\.name)), ["Cold", "Hot"])

        // Renaming on the phone.
        var renamed = try XCTUnwrap(phone.session.entries.first { $0.name == "Hot" })
        renamed.name = "Hot (daily)"
        phone.session.upsert(renamed)
        try await waitUntil("the rename reaches iCloud") {
            guard let stored = await server.record(for: renamed.id.uuidString) else { return false }
            return (try? VaultSync.open(stored.payload, id: renamed.id.uuidString, dek: phone.session.dek))?
                .name == "Hot (daily)"
        }
        await mac.coordinator.syncIfEnabled(session: mac.session)
        XCTAssertEqual(Set(mac.session.entries.map(\.name)), ["Cold", "Hot (daily)"])

        // Grouping on the Mac.
        let group = mac.session.addGroup(name: "Savings", chain: .evm, colorHex: nil)
        let cold = try XCTUnwrap(mac.session.entries.first { $0.name == "Cold" })
        mac.session.move(entryID: cold.id, toGroup: group.id)
        try await waitUntil("the group reaches iCloud") {
            await server.liveRecordIDs.count == 3
        }
        await phone.coordinator.syncIfEnabled(session: phone.session)
        XCTAssertEqual(phone.session.groups.map(\.name), ["Savings"])
        XCTAssertEqual(phone.session.entry(id: cold.id)?.groupID, group.id)

        // Deleting on the phone.
        phone.session.delete(id: renamed.id)
        try await waitUntil("the deletion reaches iCloud") {
            await !server.liveRecordIDs.contains(renamed.id.uuidString)
        }
        await mac.coordinator.syncIfEnabled(session: mac.session)
        XCTAssertEqual(mac.session.entries.map(\.name), ["Cold"], "the deleted wallet came back")

        // And both are quiet afterwards.
        let macFinal = await mac.coordinator.syncIfEnabled(session: mac.session)
        let phoneFinal = await phone.coordinator.syncIfEnabled(session: phone.session)
        XCTAssertEqual(macFinal?.changedLocally, false)
        XCTAssertEqual(phoneFinal?.changedLocally, false)
        XCTAssertEqual(macFinal?.pushed, 0)
        XCTAssertEqual(phoneFinal?.pushed, 0)
    }

    // MARK: - Helpers

    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting until \(what)")
    }
}
