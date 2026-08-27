# SafeKey

A local, fully encrypted vault for crypto wallet secrets — seed phrases and
private keys — on **macOS 26** (styled after Apple's Passwords app) and
**iOS 26**.

No accounts, no telemetry, no servers of ours. The vault lives on the device
and nothing leaves it unless you switch on iCloud sync, which is off until you
do — and even then only ciphertext travels.

Both apps compile the same `SafeKeyCore` framework, so the encryption, the
container format, and the self-destruct accounting are one audited source
rather than two implementations that can drift apart. A vault exported from one
opens on the other.

## Security model

| Layer | What it does |
|---|---|
| **Encryption** | AES-256-GCM over the whole vault payload (CryptoKit) |
| **Key derivation** | PBKDF2-HMAC-SHA256, calibrated to ≈250 ms, never under 600,000 iterations |
| **Envelope** | Random 256-bit data key encrypts the vault; that key is wrapped by your password-derived key, so changing your password never re-encrypts your data |
| **Tamper detection** | The plaintext header is authenticated as GCM additional data. Because that check runs only *after* a successful unwrap, destructive decisions instead use a trust anchor pinned at the last successful unlock — a modified vault file is detected and reported before you type anything |
| **Touch ID** | Optional. Keeps a biometry-protected copy of the data key in the Keychain |
| **USB security key** | Optional second factor, cryptographically enforced: the data key is wrapped under `HKDF(passwordKEK ‖ deviceKey)`, so the right password without the stick cannot open the vault. Enabling it **rotates** the data key, so older backups plus the password cannot decrypt anything written afterwards |
| **Self-destruct** | Optional. After N wrong passwords, deletes every wrapped copy of the key (both Keychain domains) and the vault file. Fires only under the *pinned* policy on an *unmodified* file, so no one can weaponize it against you. With iCloud sync on it erases **this device** — the copy in iCloud and on your other devices is deliberately left alone, or taking one device would be enough to destroy the vault everywhere |
| **At rest** | Vault file is `0600`, written atomically (temp + rename), never partially written |
| **On screen** | macOS: `NSWindow.sharingType = .none` hides windows from screenshots, recordings, and screen sharing — on by default, toggleable in Settings → Security. iOS: screenshots cannot be blocked by any app, but while the screen is being recorded, mirrored, or streamed, reveal is refused and anything revealed hides itself |
| **In memory** | Locking drops the session so ARC releases the secrets; auto-lock on sleep, screen lock, and inactivity |
| **Clipboard** | Copied secrets are marked concealed and auto-cleared, but only if you haven't copied something newer |
| **Keyboard** | iOS refuses third-party keyboard extensions app-wide — a custom keyboard is someone else's code seeing every keystroke, so only Apple's keyboard ever gets one. Same policy as Apple's Passwords app |
| **iCloud sync** | Off by default. Each wallet is sealed under the vault's data key *before* it is uploaded, so iCloud holds an opaque blob, a date and a vault id — never a name, a chain, or a secret |
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

## iCloud sync

Off unless you turn it on, and only across your own Apple devices, through your
own private CloudKit database.

Each wallet travels as its own record rather than the vault travelling whole:
two sealed vaults cannot be merged, so whoever saved last would silently erase
the other device's work. Per wallet, a clash costs one wallet — and even then
both versions are kept, the incoming one alongside the local one as a
*conflicted copy*, because a vault is the wrong place to let a clock decide
which of your keys survives.

What the sync engine keeps between runs is a change token and, per record, a
digest of the version iCloud is known to hold. A digest rather than a
timestamp: vault dates have whole-second precision, so an edit made in the same
second as the last sync would look like the version already sent and would
never leave the device. The digest also tells this device's own record coming
back to it apart from a genuine edit on the other one.

Deletions are written down before they are sent, in the same file: a deletion
that lived only in memory would die with the app, and the record it should have
removed would come back on the next full fetch as if it were new.

A password change is per device. The wallets travel sealed under the vault's
data key, and re-wrapping that key under a new password leaves the data key
alone — so the other device carries on syncing with the password it already
has, and both remain correct. Changing it everywhere means changing it on each
device; the app says so where you change it.

The vault's header is uploaded too — a salt, the KDF parameters, and the data
key wrapped under your password, the same material an exported backup already
contains. It is what lets a second device join by typing the master password
instead of shuttling a file around. A device never publishes its header over a
*different* vault's: those records are sealed under a key only their own header
carries, so replacing it would strand them permanently. Instead the app says
the account holds another vault and offers to merge the two, adopt that one, or
replace it.

## Disguise

SafeKey can present itself as something else:

- **Dock-level** — swaps the running app's icon and title instantly, remembered
  across launches.
- **Bundle rebrand** — rewrites `CFBundleDisplayName`/`CFBundleName` and the
  `.icns` inside the app bundle, re-signs ad-hoc, and relaunches, so Finder,
  Spotlight, and the Dock all show the disguise. The bundle identifier is never
  touched (the vault path and Keychain items depend on it). The name and icon
  are reversible from the same screen; **the signature is not**. Re-signing
  replaces the app's entitlements, and an ad-hoc signature cannot carry the
  Keychain access group or the iCloud container, so Touch ID unlock and iCloud
  sync stop working until SafeKey is reinstalled. The app says so before it
  rebrands. Nothing about the vault itself is affected.

Presets include document-style icons ("Quarterly Report", "Receipts 2024") that
read as files rather than apps when extensions are hidden, plus a free-text
custom name.

## Build & run

### macOS

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

### iOS

```bash
xcodegen generate && xcodebuild -project SafeKey.xcodeproj -scheme SafeKeyiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
```

The whole iOS suite — 87 core tests plus 17 UI tests covering vault creation,
adding wallets, revealing a secret, lock/unlock, wrong password, relaunch
persistence, search, settings, Face ID, self-destruct, and groups:

```bash
xcodebuild -project SafeKey.xcodeproj -scheme SafeKeyiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build test
```

UI tests run against an isolated vault (`--uitest`) in a scratch directory
under their own Keychain service, so they can never touch a real vault. The
hook is compiled out of release builds.

Two suites are worth knowing about:

- `SelfDestructUITests` arms self-destruct through the real settings UI and
  burns the attempts, checking the vault is erased **and stays erased across a
  relaunch** — and that a correct password resets the counter, so a near-miss
  cannot carry over and erase the vault weeks later.
- `LayoutUITests` rotates to landscape and checks every control is still
  reachable. The lock and onboarding screens cap their content at a 460pt
  centred column: without it a landscape iPhone — and every iPad — renders a
  password field the full width of the screen.
- `BackupRoundTripiOSTests` covers the recovery path the UI tests cannot reach
  (export and restore go through the system document picker): entries survive a
  round trip, the exported file holds no plaintext, a rejected import leaves the
  vault untouched, a restore keeps a rescue copy of what it replaced, and a
  backup still opens with the password it had when it was saved.

Face ID cannot authenticate itself inside the simulator — the sensor is driven
from the host. Run the matcher alongside the biometric test:

```bash
scripts/simulator_faceid_match.sh <simulator-udid> 400
```

`ScreenshotTourUITests` walks every screen and writes PNGs into the test
runner's container, for reviewing the UI without driving the simulator by hand:

```bash
xcrun simctl get_app_container <udid> com.andri.safekey.uitests.ios.xctrunner data
```

The suites also run on iPad (`-destination 'platform=iOS Simulator,name=iPad
Pro 11-inch (M5)'`). iPad gets the iPhone layout enlarged rather than a
purpose-built one — no split view — which is a deliberate v1 choice, not an
oversight. `TARGETED_DEVICE_FAMILY: "1"` would restrict to iPhone.

**Installing on a real iPhone.** The simulator build is signed ad-hoc, which
a device will not run. For a device build set a signing identity and let Xcode
manage the profile:

```bash
xcodebuild -project SafeKey.xcodeproj -scheme SafeKeyiOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=RR9A8973M8 CODE_SIGN_IDENTITY='Apple Development' \
  -derivedDataPath build build
```

`Sources/SafeKeyiOS/SafeKeyiOS.entitlements` already carries the matching
team-prefixed `application-identifier`. Without that entitlement iOS refuses
every Keychain call with `errSecMissingEntitlement`, and Face ID unlock fails
with no visible error — so if biometrics ever stops working on device, check
the entitlement before anything else.

**What differs on iOS.** No USB security key (no port for it) and no app
disguise (an app cannot rewrite its own bundle, and concealment sits badly with
App Store review — alternate app icons are the sanctioned equivalent). Instead
iOS adds a privacy cover that hides the UI from the app-switcher snapshot, and
locks whenever the app leaves the foreground. Everything else — self-destruct,
password change, encrypted backup and restore, chain-scoped groups, tags, real
chain artwork, Solana address derivation — is present on both.

Try the macOS UI without touching your real vault — a throwaway temp vault with
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
Sources/SafeKey/        macOS SwiftUI app
  Main/                 Three-pane UI: sidebar tiles, entry list, detail
  Settings/             General, Security, Self-Destruct, Disguise
  Services/             Auto-lock, clipboard guard, volume watcher, disguise
Sources/SafeKeyiOS/     iOS SwiftUI app (list → detail, sheets, privacy cover)
Sources/SafeKeyShared/  Used by both apps: vault session, chain artwork, SVG
Tests/SafeKeyCoreTests/ Headless unit tests — no UI, no Keychain, no USB needed
Tests/SafeKeyiOSUITests/ End-to-end iOS flows, biometrics, screenshot tour
scripts/                Icon generation, simulator Face ID driver
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
