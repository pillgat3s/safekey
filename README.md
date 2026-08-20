# SafeKey

A local, fully encrypted macOS vault for crypto wallet secrets — seed phrases
and private keys — styled after Apple's Passwords app on macOS 26.

Nothing leaves the machine. No accounts, no sync, no telemetry, no network code
in the app at all.

## Security model

| Layer | What it does |
|---|---|
| **Encryption** | AES-256-GCM over the whole vault payload (CryptoKit) |
| **Key derivation** | PBKDF2-HMAC-SHA256, calibrated to ≈250 ms, never under 600,000 iterations |
| **Envelope** | Random 256-bit data key encrypts the vault; that key is wrapped by your password-derived key, so changing your password never re-encrypts your data |
| **Tamper detection** | The plaintext header is authenticated as GCM additional data. Because that check runs only *after* a successful unwrap, destructive decisions instead use a trust anchor pinned at the last successful unlock — a modified vault file is detected and reported before you type anything |
| **Touch ID** | Optional. Keeps a biometry-protected copy of the data key in the Keychain |
| **USB security key** | Optional second factor, cryptographically enforced: the data key is wrapped under `HKDF(passwordKEK ‖ deviceKey)`, so the right password without the stick cannot open the vault. Enabling it **rotates** the data key, so older backups plus the password cannot decrypt anything written afterwards |
| **Self-destruct** | Optional. After N wrong passwords, deletes every wrapped copy of the key (both Keychain domains) and the vault file. Fires only under the *pinned* policy on an *unmodified* file, so no one can weaponize it against you |
| **At rest** | Vault file is `0600`, written atomically (temp + rename), never partially written |
| **On screen** | `NSWindow.sharingType = .none` hides windows from screenshots and screen recording |
| **In memory** | Locking drops the session so ARC releases the secrets; auto-lock on sleep, screen lock, and inactivity |
| **Clipboard** | Copied secrets are marked concealed and auto-cleared, but only if you haven't copied something newer |
| **Logs** | `WalletEntry.debugDescription` is redacted; state restoration and sudden termination are disabled so no window snapshot ever hits disk |

### Audit

The crypto core was put through an adversarial multi-agent audit: five
independent reviewers attacking different dimensions (AEAD envelope and KDF,
second-factor bypass, container parsing and tamper-and-return, self-destruct
accounting and Keychain, app state machine), then independent skeptics trying to
*refute* each finding, with the survivors reproduced by compiled
proof-of-concept before being accepted.

Verdict: the envelope, the AAD binding, the container parser bounds, and the
two-factor derivation held up — no path to plaintext without the password. What
did not hold was the **trust boundary around the plaintext header**. Three
confirmed defects, all now fixed and pinned by regression tests in
[TamperAttackTests.swift](Tests/SafeKeyCoreTests/TamperAttackTests.swift):

1. **Forced self-destruct (critical).** Self-destruct policy was read from the
   unauthenticated header on the failure path, where the GCM tag cannot fire.
   Someone with write access and no password could arm it, corrupt the salt, and
   have your *correct* password erase the vault. Now: policy and counter come
   from a pinned anchor, and destruction requires the on-disk header to match
   the one pinned at your last successful unlock.
2. **Counter evasion.** The attempt counter was keyed to the header's `vaultID`,
   which an attacker could rewrite before every guess to reset it. Now keyed to
   a fixed account, with the file mirror HMAC-authenticated so a forged count
   cannot force a wipe.
3. **Incomplete shredding.** `deleteAll()` queried only the legacy Keychain, so
   the biometric copy of the data key survived a self-destruct. Now both
   domains, plus the UserDefaults strategy markers.

Also fixed: a one-byte edit to the iteration count could trap the process and
permanently brick the app; the data key is now rotated on policy change; and
`keyFileRelPath` is path-traversal checked.

### Honest limits

- **Self-destruct is not magic.** It defeats someone guessing passwords at this
  app. It cannot help if an attacker copied `vault.safekey` first — there, your
  password strength and the slow KDF are the entire defense. The overwrite pass
  is best-effort: on APFS/SSD the original blocks may survive. The real deletion
  is cryptographic (every wrapped copy of the key is destroyed).
- **Self-destruct disables itself on a modified vault file.** That is
  deliberate: an attacker must never be able to turn your own protection into a
  weapon against you. If you see the tamper warning on the unlock screen, your
  vault file changed since you last opened it — restore from a backup you trust
  before entering anything.
- **A backup taken before you enabled the USB factor is still a backup of that
  era's data**, decryptable with the password of that era. Rotation protects
  everything written afterwards, not what was already in the snapshot.
- **Lose the USB key and its backup with the factor enabled and the vault is
  gone.** There is no recovery path, by design. Export the backup key file the
  setup flow offers you.
- **Screen-capture blocking stops software.** It does not stop a phone camera.
- Swift cannot reliably zero `String`/`Data` in memory. The mitigation is
  aggressive locking, not a guarantee.

## Disguise

SafeKey can present itself as something else:

- **Dock-level** — swaps the running app's icon and title instantly, remembered
  across launches.
- **Bundle rebrand** — rewrites `CFBundleDisplayName`/`CFBundleName` and the
  `.icns` inside the app bundle, re-signs ad-hoc, and relaunches, so Finder,
  Spotlight, and the Dock all show the disguise. The bundle identifier is never
  touched (the vault path and Keychain items depend on it). Reversible from the
  same screen.

Presets include document-style icons ("Quarterly Report", "Receipts 2024") that
read as files rather than apps when extensions are hidden, plus a free-text
custom name.

## Build & run

```bash
xcodegen generate && xcodebuild -project SafeKey.xcodeproj -scheme SafeKey -configuration Debug -derivedDataPath build build
```

Run it:

```bash
open build/Build/Products/Debug/SafeKey.app
```

Tests (37 unit tests covering the crypto core, container format, atomic
storage, self-destruct accounting, and the device factor):

```bash
xcodebuild -project SafeKey.xcodeproj -scheme SafeKey -destination 'platform=macOS' -derivedDataPath build test
```

Try the UI without touching your real vault — a throwaway temp vault with
sample wallets:

```bash
SAFEKEY_DEMO=1 ./build/Build/Products/Debug/SafeKey.app/Contents/MacOS/SafeKey
```

`SAFEKEY_DEMO_STATE=locked` starts at the unlock screen (demo password:
`demo-password-123`). `SAFEKEY_ALLOW_CAPTURE=1` disables screen-capture
blocking so you can record the UI. All three are DEBUG-only.

## Layout

```
Sources/SafeKeyCore/    Crypto, vault format, storage, unlock factors (no UI imports)
  Crypto/               PBKDF2, AES-GCM envelope, HKDF two-factor combine
  Vault/                Container codec, atomic store, self-destruct accounting
  Unlock/               Password, biometric, and USB device-key factors
  Keychain/             SecItem wrapper behind a protocol (tests use a fake)
Sources/SafeKey/        SwiftUI app
  Main/                 Three-pane UI: sidebar tiles, entry list, detail
  Settings/             General, Security, Self-Destruct, Disguise
  Services/             Auto-lock, clipboard guard, volume watcher, disguise
Tests/SafeKeyCoreTests/ Headless unit tests — no UI, no Keychain, no USB needed
scripts/                Icon generation
FORMAT.md               Byte-level vault spec (for the planned Windows port)
```

The core is deliberately free of AppKit and SwiftUI so the security-critical
code tests headlessly and ports cleanly.

## Extending unlock

`UnlockFactor` (in `Sources/SafeKeyCore/Unlock/UnlockFactor.swift`) is the
extension point. A new factor either contributes key material to the KEK
derivation (like the USB key) or produces the data key directly (like Touch ID).

## Distribution notes

The current build is ad-hoc signed for personal use. Selling it outside the Mac
App Store needs a Developer ID certificate and notarization. Note that the
bundle-rebrand disguise re-signs ad-hoc, which conflicts with a notarized
signature — that flow needs rethinking before release (a signed helper, or
Dock-level disguise only). The Mac App Store is not an option for the rebrand
feature at all, since the sandbox forbids an app modifying its own bundle.
