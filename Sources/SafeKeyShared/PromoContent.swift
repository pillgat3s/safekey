#if DEBUG
import Foundation
import SafeKeyCore

/// The demo vault both apps show when filmed or screenshotted for marketing.
///
/// Burner-trader content, which is what SafeKey is for. Every value here is invented: the phrases are random picks from the
/// BIP-39 word list, the keys and addresses random strings in each chain's
/// format. None of it has ever held funds, and none of it is a published test
/// vector — those are recognisable at a glance and look staged on screen.
/// Debug builds only.
enum PromoContent {
    static let password = "Correct-Horse-9"

    static let sniperBots = UUID(uuidString: "5A4E3C1B-0000-4000-8000-000000000001")!
    static let airdropFarms = UUID(uuidString: "5A4E3C1B-0000-4000-8000-000000000002")!
    static let retired = UUID(uuidString: "5A4E3C1B-0000-4000-8000-000000000003")!

    static func payload(now: Date = .vaultNow()) -> VaultPayload {
        func ago(_ days: Double) -> Date {
            Date(timeIntervalSince1970: (now.timeIntervalSince1970 - days * 86_400).rounded(.down))
        }
        var settings = VaultSettings()
        settings.cloudSyncEnabled = false
        settings.blockScreenCapture = false
        settings.revealPolicy = .never

        let groups = [
            WalletGroup(id: sniperBots, name: "Sniper Bots", chain: .solana, colorHex: "#FF9F0A", icon: "bolt.fill", sortIndex: 0, modifiedAt: ago(30)),
            WalletGroup(id: airdropFarms, name: "Airdrop Farms", chain: .evm, colorHex: "#BF5AF2", icon: "sparkles", sortIndex: 0, modifiedAt: ago(30)),
            WalletGroup(id: retired, name: "Retired", chain: .bitcoin, colorHex: "#8E8E93", icon: "archivebox.fill", sortIndex: 0, modifiedAt: ago(30)),
        ]

        let entries = [
            WalletEntry(name: "Daily Burner", chain: .evm, kind: .seedPhrase(wordCount: 12),
                        secret: "bridge silent canyon zebra kingdom saddle timber jungle frost jaguar hover yellow",
                        publicAddress: "0x4D196e563AB87a0dB8025cf5D34c45562b11E789",
                        notes: "Day-to-day degen wallet. Small balance only.", tags: ["daily"], favorite: true,
                        createdAt: ago(320), modifiedAt: ago(0)),
            WalletEntry(name: "Sniper Bot 1", chain: .solana, kind: .privateKey,
                        secret: "ycD6nHxwEnKXxEAryaHKPs51Ew5r3ptW7FhDhLm47oD34oYvdV9deFnmFDijk8pwSt2sRTyzvbAEwTVg7ZtJdVdN",
                        publicAddress: "EJ8zpafyobWegAvNgAZRLgssRNqhTRziSHQzd9BvoMeJ",
                        tags: ["bot"], groupID: sniperBots, favorite: true, createdAt: ago(40), modifiedAt: ago(1)),
            WalletEntry(name: "Sniper Bot 2", chain: .solana, kind: .privateKey,
                        secret: "mHm1KAMZuEk9LvDDo1LqiVjx1pBc5km6rg8Q64CFkifgoEG8YRLhBoS9s1ujq7ABNE7DQHriUSrkN7YjvwSa6amf",
                        publicAddress: "ygMTjyMoQaZTQT3s2hEKE6aGXbYmQYCFxBhErWqhbWVm",
                        tags: ["bot"], groupID: sniperBots, createdAt: ago(60), modifiedAt: ago(8)),
            WalletEntry(name: "Airdrop Farm A", chain: .evm, kind: .privateKey,
                        secret: "0x7cd5ef4058e0970f2905252576dcc31cba5666333ea0d9435262aa711ba81459",
                        publicAddress: "0xAc3be93EEf85917231a26E46c6d956Be95D1987a",
                        tags: ["airdrop"], groupID: airdropFarms, createdAt: ago(150), modifiedAt: ago(2)),
            WalletEntry(name: "Airdrop Farm B", chain: .evm, kind: .privateKey,
                        secret: "0x7d9b7af30aa33c8e97b6d9e5ecb337f43242707d403480299003a3072f1bc39d",
                        publicAddress: "0xc4D4579660c629d7fc23020Ff32DD228C2Ae9E5B",
                        tags: ["airdrop"], groupID: airdropFarms, createdAt: ago(180), modifiedAt: ago(20)),
            WalletEntry(name: "Pump Burner", chain: .solana, kind: .seedPhrase(wordCount: 12),
                        secret: "noble meadow tiger garden planet summit wisdom jungle salmon rocket lunar canyon",
                        publicAddress: "s3f6YSXo7JUqo7yA5Zrgee2aaWWw4PeSRkkn1rCXULWN",
                        tags: ["memecoins"], createdAt: ago(210), modifiedAt: ago(5)),
            WalletEntry(name: "Mint Burner", chain: .evm, kind: .privateKey,
                        secret: "0xcff1c438c2bf22bf5e19ce4fc01396ab89de3940cb00d58702904ec86dbfd3c0",
                        publicAddress: "0x7E8C5C0f9864c27223d58630191d69CFce1761cA",
                        createdAt: ago(90), modifiedAt: ago(40)),
            WalletEntry(name: "Presale Burner", chain: .evm, kind: .seedPhrase(wordCount: 24),
                        secret: "mercy vivid spice canyon unique sketch thunder breeze kitten meadow velvet dragon mountain bridge ocean yellow cradle oyster vessel summit coral umbrella youth raven",
                        publicAddress: "0x04164228c89a4D516e3020BC03C11Cd530F08B52",
                        notes: "Used once for a presale. Nothing left in it.", favorite: true,
                        createdAt: ago(500), modifiedAt: ago(12)),
            WalletEntry(name: "Points Farm", chain: .known(.ton), kind: .seedPhrase(wordCount: 24),
                        secret: "youth canvas spice kingdom coral glimpse oyster frost jungle novel eagle ladder shadow ripple kitten mercy quantum width zebra voyage anchor rocket zone walnut",
                        publicAddress: "UQLWifqwPQ-Dd_MBSv_Ld5MfYP1F3w7MhtY5YXXsT6ctT7s8",
                        tags: ["airdrop"], createdAt: ago(100), modifiedAt: ago(15)),
            WalletEntry(name: "Giveaway Burner", chain: .bitcoin, kind: .seedPhrase(wordCount: 12),
                        secret: "jaguar vessel vivid olive yellow marble spice wisdom dragon violin planet noble",
                        publicAddress: "bc1qsc3xawhddfnjwns7w9zssj5e6xcy3cm07re6sh",
                        groupID: retired, createdAt: ago(700), modifiedAt: ago(60)),
            WalletEntry(name: "Ordinals Burner", chain: .bitcoin, kind: .seedPhrase(wordCount: 24),
                        secret: "orbit palace cradle marble glimpse raven fossil zebra lobster copper olive anchor kingdom lemon frost unveil crystal quantum zone rocket galaxy velvet vessel ripple",
                        publicAddress: "bc1qe9ycflh5xjr673vpsce03ddpfk52ydw39dtsg4",
                        notes: "Emptied. Kept for the transaction history.", groupID: retired,
                        createdAt: ago(900), modifiedAt: ago(120)),
            WalletEntry(name: "Test Wallet", chain: .bitcoin, kind: .seedPhrase(wordCount: 24),
                        secret: "copper bridge marble timber lunar ocean eagle insect cradle dragon coral lemon thunder voyage salmon harvest tiger oyster olive meadow echo crystal umbrella orbit",
                        publicAddress: "bc1qqrn0l2t07p9a4snltcpnpxljt4p0pkrlr6hkh5",
                        tags: ["testnet"], groupID: retired, createdAt: ago(600), modifiedAt: ago(3)),
        ]
        return VaultPayload(entries: entries, settings: settings, groups: groups)
    }
}
#endif
