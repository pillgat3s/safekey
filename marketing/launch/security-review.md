# What SafeKey actually does with your data

A review of the code as of October 2026, written so that marketing claims
can be checked against it. Nothing here is aspirational; where the app has a
limit, the limit is stated.

## Network

SafeKey has no network code of its own. There is no `URLSession`, no socket,
no web view, no analytics or crash-reporting library, and no third-party
code at all (the project has no package dependencies). The app never
contacts a server we run, because there is none.

Two optional features use Apple's network, and both are off until switched
on:

- **iCloud sync** (iPhone and Mac) uses CloudKit, Apple's framework, to put
  records in the private database of *your* iCloud account. The developer
  cannot read a user's private CloudKit database.
- **"Keep an encrypted copy in iCloud Drive"** (Mac only) writes the vault
  file into your iCloud Drive folder and lets macOS sync it like any file.

Entitlements, iPhone: application identifier, keychain access group, iCloud
container, iCloud services (CloudKit). A push-notification entitlement that
nothing used was removed in this review. Mac: iCloud container and iCloud
services only. The Mac app is **not sandboxed** (the USB security-key and
app-disguise features need the filesystem). No App Transport Security
exceptions, no background modes.

Solana address derivation is done on the device with code in the app, not by
asking a network.

## What is stored, and where

### iPhone

| Item | Where | Protection |
|---|---|---|
| The vault (`vault.safekey`) | the app's Application Support folder | SafeKey's own encryption (below) **and** iOS data protection "complete unless open": unreadable while the phone is locked unless the app already has it open. Included in iCloud Backup by default; a switch in Settings excludes it. |
| Sync bookkeeping (`sync.json`, only with sync on) | next to the vault | Same iOS data protection. Holds the CloudKit change token and a SHA-256 fingerprint per wallet, taken over the wallet's full contents including its secret, so it cannot be reversed. No secrets. |
| Self-destruct anchor (`anchor.dat`) | next to the vault | Vault ID, policy, header hashes and the failed-attempt count, signed with a key held only in the Keychain. No secrets. |
| Rescue copy (`vault.safekey.pre-restore`) | next to the vault | The previous vault, kept when a backup is restored or an iCloud vault adopted; removed at the next successful unlock. Same encryption as the vault. |
| Keychain: anchor copy and its signing key | iOS Keychain, "this device only" | Available after first unlock. Never synced through iCloud Keychain, never restored to another device. No secrets. |
| Keychain: Face ID copy of the data key (only if Face ID unlock is on) | iOS Keychain, "this device only, when unlocked" | Access control `biometryCurrentSet`: the Secure Enclave releases it only for the faces enrolled at the time it was stored. Any change to Face ID enrolment invalidates it. |
| Preferences (which sections are collapsed, "Don't Show Again", Face ID strategy marker) | UserDefaults, plain | Nothing sensitive. |
| Clipboard, after Copy | system pasteboard | Marked local-only (no Universal Clipboard) and set to expire after the chosen interval (default 30 s). |

### Mac

Same vault, bookkeeping, rescue and preference files under
`~/Library/Application Support/SafeKey`. There is no per-file data protection
on macOS; the disk is protected by FileVault if the user has it on. The
Touch ID copy of the data key lives in the data-protection keychain with the
same biometric access control when the app is signed with a provisioning
profile (App Store and Developer ID builds). A build without that
entitlement falls back to a login-keychain item that the app, not the
Keychain, gates behind Touch ID; Settings shows which one is in use
("Keychain-enforced" vs "App-enforced"). The optional USB security key is a
random 32-byte file on a volume you choose; the vault's data key is then
wrapped under the password and that file together.

## How it is encrypted

- **Container.** An 8-byte magic, a version, a plaintext header, then the
  payload sealed with **AES-256-GCM** with the header bound as associated
  data. Changing a single byte of either part makes decryption fail with an
  integrity error rather than produce garbage.
- **Keys.** A random 256-bit data key encrypts the payload. The data key is
  wrapped (AES-256-GCM again) under a key derived from the master password
  with **PBKDF2-HMAC-SHA256**, a 32-byte random salt, and an iteration
  count calibrated to about 250 ms on the device that created the vault,
  never below 600,000 (the OWASP minimum). Every seal uses a fresh random
  12-byte nonce.
- **Inside the payload**, so encrypted: every wallet's name, secret, public
  address, notes and tags; group names; the app's settings.
- **In the plaintext header**, so visible to anyone holding the file: a
  vault ID, creation date, the salt and iteration count, the wrapped data
  key, whether self-destruct is on and after how many attempts, and whether
  a USB key is required (with the volume's name). None of this helps decrypt.
- **Changing the master password** re-wraps the data key; the wallets are
  not re-encrypted. A copy of the vault file taken *before* the change still
  opens with the *old* password. That is how every design of this kind
  works, but it is worth knowing.
- **Sync** uploads each wallet as AES-256-GCM ciphertext under the data key
  plus its modification date, and the vault header as above. iCloud (and
  therefore Apple) can see: how many wallets you have, when each changed,
  the vault ID, the salt and iteration count, the wrapped key, and
  ciphertext. It cannot read a wallet, and neither can we.
- **The master password is never stored**, and there is no recovery. Forget
  it and the vault is gone.
- **Memory.** While the vault is open, the data key and the decrypted
  wallets are in the app's memory. Locking discards them; the memory is
  released, not scrubbed byte by byte.

## What an attacker gets

**A locked iPhone, passcode unknown.** Nothing. The vault file and the
Keychain items are behind iOS data protection, which is tied to the passcode
and the Secure Enclave. Without the passcode they cannot even read the
ciphertext in practice.

**An unlocked iPhone in their hands (passcode known, or grabbed while
unlocked).** SafeKey locks the moment it leaves the foreground, so they
arrive at a lock screen. Their face does not match. If they know the
passcode and enrol their own face, the Face ID key copy is invalidated by
the Secure Enclave, so that path is closed too; they need the master
password. What they *can* do is copy the encrypted vault file (through a
computer backup, or a jailbreak) and guess passwords offline. Each guess
costs about 250 ms on phone hardware; a GPU rig manages on the order of ten
thousand guesses per second per GPU against these parameters. A password
from a wordlist or a short one falls; a long random one does not. The
on-device self-destruct cannot help against a copied file. The app's
only hard requirement is eight characters, with a strength meter; raising
that floor is a product decision worth considering.

**An unlocked iPhone with SafeKey already open.** They see what you see and
can reveal and copy wallets until the app leaves the foreground. There is
no inactivity timer on the iPhone today (the Mac has one). "Ask before
revealing" in Settings puts Face ID in front of every reveal, but it is off
by default. Both are worth saying out loud rather than papering over.

**A Mac, locked or asleep.** The vault file is readable by anyone who can
log in as you, or who has the disk without FileVault. It is ciphertext, so
the offline password attack above is what they are left with. The Touch ID
key copy is Secure Enclave-bound on signed builds.

**Malware running as you on the Mac.** As for any app: it can copy the
encrypted file, read the clipboard between Copy and the auto-clear, and log
the master password as you type it. SafeKey marks copied secrets as
concealed and clears them, which defeats casual clipboard managers, not a
keylogger.

**Your iCloud account.** With sync on: ciphertext and the metadata listed
above, nothing readable. With iCloud Backup including the vault: the same
ciphertext inside the device backup.

**Someone looking at your screen.** A revealed key is visible to a person
holding the phone. It is not visible to screenshots, screen recordings,
mirroring or AirPlay on the iPhone, and the Mac's windows come out blank in
captures while that setting is on (the default).

**Us.** Nothing. No servers, no analytics, no telemetry, no way to read a
private CloudKit database. If Apple's crash reporting is on, Apple gets
crash logs; they contain no vault contents.

## Claims you can make, and ones you cannot

True and specific:

- Encrypted on your device with AES-256-GCM; the key comes from your master
  password through PBKDF2 (600,000+ iterations) and is never stored.
- No account, no servers, no analytics, no tracking, no third-party code.
- Nothing leaves the device unless you turn on iCloud sync or a backup, and
  then only ciphertext leaves.
- Face ID / Touch ID unlock backed by the Secure Enclave; re-enrolling Face
  ID invalidates the stored key.
- Revealed keys are invisible to screenshots and screen recordings (iPhone)
  and screen capture (Mac, by default).
- Locks whenever it leaves the foreground on iPhone; on sleep, screen lock
  and inactivity on Mac.
- Optional self-destruct after a chosen number of wrong passwords, with the
  file kept safe against forged attempt counts.
- Tamper detection: a modified vault file is refused, not opened.

Do not claim:

- "Unhackable", "bank-grade", "military-grade", or anything implying the
  app survives a weak master password or a compromised device.
- That a forgotten password can be recovered, or that self-destruct protects
  a copied file.
- That the Mac app is sandboxed.
- That it is suitable for significant funds. That is the positioning, and
  it is also the engineering truth: the security of a software vault is
  bounded by the device it runs on and the password you choose.
