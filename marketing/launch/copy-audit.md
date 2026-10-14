# In-app copy audit for the burner-wallet positioning

Every user-visible string in both apps was read (633 literals). The lines
below are the ones that implied SafeKey is a place for everything you own,
or that named a storage product. Everything else — settings explainers,
sync and backup text, self-destruct, error messages — already talks about
the vault, the password and the device without promising to guard a
fortune, and was left alone.

| Where | Before | After |
|---|---|---|
| iPhone welcome, first row | **Never Lose a Seed Phrase** — Every recovery phrase and private key in one place, ready the moment you need it. | **Your Burners, in One Place** — The throwaway wallets you'd otherwise keep in Notes or screenshots — encrypted, and ready when you need them. |
| iPhone onboarding, lead | An encrypted vault for your wallet recovery phrases and private keys. Everything stays on this device unless you later turn on iCloud sync. | An encrypted vault for the recovery phrases and private keys of your burner wallets. Everything stays on this device unless you later turn on iCloud sync. |
| Mac welcome card | A local, fully encrypted vault for your wallet seed phrases and private keys. Nothing leaves this Mac unless you later turn on iCloud sync. | A local, fully encrypted vault for the seed phrases and private keys of your burner wallets. Nothing leaves this Mac unless you later turn on iCloud sync. |
| iPhone add-wallet, name placeholder | e.g. Main Wallet | e.g. Sniper Bot 3 |
| Mac add-wallet, name placeholder | e.g. Main EVM Wallet | e.g. Sniper Bot 3 |
| Solana address derivation, path label | Solana CLI, Ledger (account 1) | Solana CLI (account 1) |
| Demo vault (debug builds, screenshots, film): wallet names | Main Wallet, Cold Storage, Ledger Backup, Staking, Sniper Bot, Airdrop Farm, DeFi Vault, Yield Farming, NFT Mint, Treasury, TON Wallet, Inheritance | Daily Burner, Sniper Bot 1, Sniper Bot 2, Airdrop Farm A, Airdrop Farm B, Pump Burner, Mint Burner, Presale Burner, Points Farm, Giveaway Burner, Ordinals Burner, Test Wallet |
| Demo vault: groups | Cold Storage, DeFi, Trading | Sniper Bots, Airdrop Farms, Retired |
| Demo vault: notes | "Everyday wallet. Keep the balance small." / "Metal plate copy in the safe." / "Sealed copy with the lawyer." | "Day-to-day degen wallet. Small balance only." / "Used once for a presale. Nothing left in it." / "Emptied. Kept for the transaction history." |
| Tests: sample entry names | "Ledger", "Ledger Nano X — Long Term Cold Storage" | "Burner", "Presale Burner — One-Time Use" |

New copy added by steps 1 and 2 (first-run notice and add-wallet reminder)
is in `Sources/SafeKeyShared/ScopeNotice.swift`.

## Left as is, on purpose

- **"XRP Ledger"** in the chain list. That is the network's name, not a
  product. Renaming it would mislabel the chain.
- **"TREZOR"** as a BIP-39 passphrase in two unit tests. It is the passphrase
  of the published BIP-39 test vectors; the tests check derivation against
  known answers and would stop meaning anything with another value. It is
  not visible anywhere in the app.
- **Self-destruct, USB security key, tamper detection, screen-capture
  blocking.** These describe what the app does; they do not claim it should
  hold your net worth. The self-destruct explainer already spells out its
  limits.

## Outside the app, still to do

- `README.md` opens with "A native macOS + iOS vault for crypto wallet
  secrets" and the security-model table. It reads as general-purpose and
  should get a positioning paragraph when the repo goes public.
- The promotional film: "Twelve words. Your whole wallet.", "Every key. One
  vault.", the "Ledger Backup" row in the Mac footage. To be remade later, as
  agreed; the demo vault it will be shot from is already updated.
