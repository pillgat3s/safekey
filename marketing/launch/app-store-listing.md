# App Store listing — SafeKey (iOS and macOS)

Crypto-adjacent apps get a careful review. Everything below says plainly
what the app does and does not do, and the review notes at the end say it
again for the reviewer.

## Name (30 characters max)

1. **SafeKey – Burner Wallet Vault** (29)
2. **SafeKey: Seed Phrase Vault** (26)
3. **SafeKey** (7) — with the subtitle doing the work

## Subtitle (30 characters max)

1. **Encrypted burner wallet keys** (28)
2. **Seed phrases, out of Notes** (26)
3. **A vault for throwaway wallets** (29)

Recommended pair: name 1 with subtitle 2. The name says what it is for and
the subtitle names the habit it replaces.

## Promotional text (170 characters, editable without a review)

For the wallets you spin up and throw away. Keys stay encrypted on your
device, open with Face ID, and never show up in a screenshot.

## Description

SafeKey is an encrypted vault for the seed phrases and private keys of your
burner wallets — the throwaway and low-value wallets that otherwise end up
in Notes, in screenshots, or in a chat with yourself.

It is not built to hold significant funds. Keep larger amounts in
dedicated, secure storage. SafeKey is honest about that on the first screen
you see.

WHAT IT DOES
• Stores seed phrases and private keys for any chain — Solana, EVM (Ethereum, Base, Arbitrum and every L2), Bitcoin, TON and more
• Encrypts everything on your device with AES-256-GCM, under a key derived from your master password
• Opens with Face ID or Touch ID, backed by the Secure Enclave
• Keeps a revealed key invisible to screenshots and screen recordings
• Locks the moment it leaves the foreground
• Groups and tags wallets by chain, so twenty burners stay findable
• Derives a Solana address from a secret on the device, so you can check a key was recorded correctly

WHAT NEVER HAPPENS
• No account. No sign-up.
• No servers. Nothing is sent anywhere unless you turn on iCloud sync, and then only ciphertext leaves your device.
• No analytics, no tracking, no third-party code.
• No transactions. SafeKey does not connect to any blockchain, hold any funds, or send anything. It stores text you give it.

OPTIONAL
• Sync across your iPhone, iPad and Mac through your own iCloud, end-to-end encrypted. Apple stores the ciphertext and cannot read it; neither can we.
• Encrypted backups you can keep wherever you like.
• Self-destruct after a chosen number of wrong passwords.
• On the Mac: an optional USB security key as a second factor, and windows that come out blank in screen captures.

ONE THING TO KNOW
Your master password is never stored and cannot be recovered. If you forget it, the vault is gone. That is the point, and it is also a responsibility.

SafeKey is for the keys you'd be fine losing — a big step up from a Notes file, not a replacement for serious storage.

## Keywords (100 characters max, comma-separated, no spaces)

seed phrase,private key,burner wallet,memecoin,solana,ethereum,crypto vault,encrypted,backup

(92 characters. Don't repeat words from the name or subtitle; the store
indexes those already.)

## Category

Primary: Utilities. Secondary: Finance.

## Age rating

4+. No gambling, no unrestricted web access, no purchase of crypto.

## Screenshots

### iPhone (6.9" and 6.5" sets)

| # | Shows | Caption |
|---|---|---|
| 1 | Home grid with the four tiles, chains and groups (demo vault) | **Your burners, in one place.** |
| 2 | First-run notice, "Made for Burner Wallets" | **Honest about what it's for.** |
| 3 | Lock screen with the Face ID scan | **Opens with a glance.** |
| 4 | A private key revealed in the detail card | **Hidden until you tap.** |
| 5 | A 12-word seed phrase in its numbered grid | **Every word, in order.** |
| 6 | The screenshot comparison: blank row on the left, key on the right | **Screenshots see nothing.** |
| 7 | Settings: Sync with iCloud, Face ID, Erase after failed attempts | **Nothing leaves unless you say so.** |

### iPad (13" set)

| # | Shows | Caption |
|---|---|---|
| 1 | Split view, sidebar plus wallet list | **Your burners, in one place.** |
| 2 | Split view with a revealed seed phrase | **Every word, in order.** |
| 3 | The first-run notice | **Honest about what it's for.** |

### Mac

| # | Shows | Caption |
|---|---|---|
| 1 | Main window: sidebar, list, a wallet selected with the key masked | **The same vault on your Mac.** |
| 2 | Seed phrase revealed in the detail pane | **Every word, in order.** |
| 3 | Settings → Security: Touch ID, USB security key, screen-capture blocking | **Touch ID. A USB key if you want one.** |
| 4 | Lock screen | **Locks when you walk away.** |

Shoot from the demo vault (debug build with `--promo` on iPhone,
`SAFEKEY_DEMO=1` on Mac), which now shows burner-trader wallets with
invented keys. Dark mode, 9:41, full signal.

## App Review notes

> SafeKey is a local, encrypted note store for cryptocurrency wallet
> credentials (seed phrases and private keys) that the user types or
> pastes in. It does not create wallets, connect to any blockchain, show
> balances, or send, receive, swap or trade anything. There are no
> accounts, no server, no in-app purchases and no advertising.
>
> To test: launch, tap Continue, tap I Understand, choose any master
> password, tap Create Vault. Tap + to add a wallet with any text as the
> secret. Face ID can be tested in the simulator or on a device; the
> password path works without it. iCloud sync is optional and off by
> default; it uses the app's CloudKit private database and syncs only
> ciphertext.
>
> Guideline 3.1.5 (i) concerns apps that facilitate virtual currency
> storage. SafeKey holds no currency and does not connect to any
> blockchain; it stores text the user already has. The developer is
> enrolled as an organization in any case.

Note for us, not for Apple: there is no guideline written for key-storage
apps, and SafeKey is not a wallet — it cannot transfer, trade or hold
anything. The nearest clause is 3.1.5 (i), "Wallets: Apps may facilitate
virtual currency storage, provided they are offered by developers enrolled
as an organization." If a reviewer ever reached for it, the organization
account already satisfies it, so there is nothing to argue.

## What not to say anywhere in the listing

No "bank-grade", no "unhackable", no "military-grade". No recommendation of
any other product or category of product for larger amounts; "dedicated,
secure storage" is the phrase. Nothing that suggests SafeKey is a wallet.
