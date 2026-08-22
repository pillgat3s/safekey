import XCTest
import CryptoKit
@testable import SafeKeyCore

/// Deterministic randomness, so a failure names the seed that produced it and
/// re-running that seed reproduces it exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random sequences of ordinary use across three devices, replayed against one
/// zone, checked for ending up in the same place.
///
/// Every other test here is a case someone thought of. This one is for the
/// cases nobody did: three devices editing, grouping, deleting and syncing in
/// an order no one chose, including the zone being wiped underneath them. The
/// bar is convergence — once the dust settles, every device holds the same
/// wallets with the same contents — not any particular winner.
final class SyncConvergenceTests: XCTestCase {
    private let dek = SymmetricKey(size: .bits256)

    func testRandomSequencesOfUseConverge() async throws {
        for seed in UInt64(1)...400 {
            try await runScenario(seed: seed, steps: 60, wipes: false)
        }
    }

    /// The same, with the zone occasionally deleted and recreated under the
    /// devices — what "Replace the iCloud copy" does to whoever is not holding
    /// the button.
    func testRandomSequencesConvergeEvenWhenTheZoneIsWiped() async throws {
        for seed in UInt64(1)...200 {
            try await runScenario(seed: seed, steps: 60, wipes: true)
        }
    }

    // MARK: - One scenario

    private func runScenario(seed: UInt64, steps: Int, wipes: Bool) async throws {
        var random = SeededGenerator(seed: seed)
        let server = CloudServer()
        var devices = (0..<3).map { _ in Device(server: server, dek: dek) }
        // Distinct, ordered dates without sleeping. Some steps reuse the
        // previous one on purpose: vault dates are whole seconds, so edits
        // sharing a timestamp are ordinary, not exotic.
        var clock = Date(timeIntervalSince1970: 1_750_000_000)

        for step in 0..<steps {
            let index = Int(random.next() % UInt64(devices.count))
            if Bool.random(using: &random) { clock.addTimeInterval(1) }

            switch random.next() % 10 {
            case 0, 1:
                var entry = WalletEntry(
                    name: "W\(seed)-\(step)",
                    chain: .evm,
                    kind: .privateKey,
                    secret: "secret-\(seed)-\(step)"
                )
                entry.modifiedAt = clock
                devices[index].payload.entries.append(entry)

            case 2, 3:
                guard !devices[index].payload.entries.isEmpty else { break }
                let target = Int(random.next() % UInt64(devices[index].payload.entries.count))
                devices[index].payload.entries[target].secret = "edit-\(seed)-\(step)"
                devices[index].payload.entries[target].modifiedAt = clock

            case 4:
                guard !devices[index].payload.entries.isEmpty else { break }
                let target = Int(random.next() % UInt64(devices[index].payload.entries.count))
                let doomed = devices[index].payload.entries.remove(at: target)
                devices[index].state.noteDeletion(walletID: doomed.id)

            case 5:
                var group = WalletGroup(name: "G\(seed)-\(step)", chain: .evm)
                group.modifiedAt = clock
                devices[index].payload.groups.append(group)

            case 6:
                guard !devices[index].payload.groups.isEmpty else { break }
                let target = Int(random.next() % UInt64(devices[index].payload.groups.count))
                devices[index].payload.groups[target].name = "renamed-\(seed)-\(step)"
                devices[index].payload.groups[target].modifiedAt = clock

            case 7:
                guard !devices[index].payload.groups.isEmpty else { break }
                let target = Int(random.next() % UInt64(devices[index].payload.groups.count))
                let doomed = devices[index].payload.groups.remove(at: target)
                for entry in devices[index].payload.entries.indices
                where devices[index].payload.entries[entry].groupID == doomed.id {
                    devices[index].payload.entries[entry].groupID = nil
                }
                devices[index].state.noteDeletion(groupID: doomed.id)

            case 8:
                guard !devices[index].payload.entries.isEmpty,
                      !devices[index].payload.groups.isEmpty else { break }
                let entry = Int(random.next() % UInt64(devices[index].payload.entries.count))
                let group = Int(random.next() % UInt64(devices[index].payload.groups.count))
                devices[index].payload.entries[entry].groupID = devices[index].payload.groups[group].id
                devices[index].payload.entries[entry].modifiedAt = clock

            default:
                try await devices[index].syncNow()
            }

            // Deliberately at a fixed point rather than at random: the wipe is
            // the event this variant exists for, and leaving it to chance means
            // some seeds never test it at all.
            if wipes, step == steps / 2 {
                await server.wipeZone()
            }
        }

        try await settle(&devices, seed: seed, wipes: wipes)

        // Everything, as each device holds it. Digests rather than models so a
        // difference in any field shows up, not just the ones a test thought
        // to check.
        let states = devices.map { device in
            Set(device.payload.entries.map { "\($0.id):\(VaultSync.version(of: $0))" })
                .union(device.payload.groups.map { "g\($0.id):\(VaultSync.version(of: $0))" })
        }
        for (index, state) in states.enumerated().dropFirst() {
            XCTAssertEqual(
                state,
                states[0],
                """
                seed \(seed): device \(index) and device 0 disagree after settling.
                only on device \(index): \(state.subtracting(states[0]).sorted())
                only on device 0: \(states[0].subtracting(state).sorted())
                """
            )
        }

        // Agreeing with each other is not enough: they could all be holding
        // something iCloud no longer has, and the next device to install the
        // app would find it missing. So ask one.
        var joining = Device(server: server, dek: dek)
        try await joining.syncNow()
        let joined = Set(joining.payload.entries.map { "\($0.id):\(VaultSync.version(of: $0))" })
            .union(joining.payload.groups.map { "g\($0.id):\(VaultSync.version(of: $0))" })
        XCTAssertEqual(
            joined,
            states[0],
            """
            seed \(seed): a device joining now would not see what the others hold.
            missing from iCloud: \(states[0].subtracting(joined).sorted())
            only in iCloud: \(joined.subtracting(states[0]).sorted())
            """
        )

        // A wallet must never end up pointing at a group that is not there.
        for (index, device) in devices.enumerated() {
            let groups = Set(device.payload.groups.map(\.id))
            for entry in device.payload.entries {
                if let groupID = entry.groupID {
                    XCTAssertTrue(
                        groups.contains(groupID),
                        "seed \(seed): device \(index) holds \(entry.name) in a group that is not in the vault"
                    )
                }
            }
        }
    }

    /// Syncs everyone round and round until nothing changes. Convergence is
    /// only meaningful once the traffic has stopped — and a sequence that never
    /// stops is itself the bug.
    private func settle(_ devices: inout [Device], seed: UInt64, wipes: Bool) async throws {
        for round in 0..<12 {
            var quiet = true
            for index in devices.indices {
                let outcome = try await devices[index].syncNow()
                if outcome.changedLocally || outcome.pushed > 0 { quiet = false }
            }
            if quiet { return }
            XCTAssertLessThan(
                round,
                11,
                "seed \(seed)\(wipes ? " (with wipes)" : ""): the devices never stopped exchanging changes"
            )
        }
    }
}
