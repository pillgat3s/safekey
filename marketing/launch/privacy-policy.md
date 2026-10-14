# SafeKey Privacy Policy

**Effective:** [date of release]
**Applies to:** SafeKey for iPhone, iPad and Mac
**Developer:** Thomann Web Solutions, Switzerland — [contact email]

SafeKey is built so that we never see your data. This policy describes
what the app stores, where, and the two optional features that involve
Apple's iCloud. It is written from the code, not from a template.

## 1. We collect nothing

SafeKey has no account system, no server of ours, and no analytics,
advertising or crash-reporting library. The app contains no third-party
code. It makes no network connection of its own. We do not receive your
wallet names, secrets, addresses, notes, tags, settings, usage data, device
identifiers or IP address, because nothing in the app sends them.

If you have agreed to share analytics with app developers in your Apple
device settings, Apple may send us crash reports for SafeKey. Those reports
contain technical details about the crash and no vault contents.

## 2. What the app stores on your device

Everything you enter stays on the device, in a single encrypted vault
file, with a small amount of bookkeeping beside it:

- **The vault**: your wallets' names, seed phrases, private keys, public
  addresses, notes and tags, your groups, and the app's settings. All of
  this is encrypted with AES-256-GCM under a key derived from your master
  password. The file's unencrypted header holds only a vault identifier,
  the creation date, the parameters needed to derive the key from your
  password, the encrypted key itself, and your self-destruct and
  security-key settings.
- **Your master password is never stored**, anywhere, in any form. We
  cannot reset or recover it. If you forget it, the vault cannot be opened.
- **Face ID / Touch ID**: if you turn biometric unlock on, a copy of the
  vault's encryption key is stored in the device Keychain protected by the
  Secure Enclave, released only for the biometrics enrolled at the time.
  The app never receives or stores your face or fingerprint; the system
  handles that.
- **Bookkeeping**: a record used by the self-destruct feature (how many
  wrong passwords have been entered), sync state if sync is on, and view
  preferences such as which sections are collapsed. None of it contains
  secrets.
- **Clipboard**: when you copy a secret, it is placed on the device
  clipboard marked as concealed and local-only, and cleared after the
  interval you choose (30 seconds by default).

On iPhone and iPad these files are additionally protected by iOS data
protection, so they are unreadable while the device is locked.

## 3. iCloud (optional, off by default)

Two features use your own iCloud account. Neither sends anything to us.

- **Sync with iCloud** keeps the vault in step across your devices through
  Apple's CloudKit, in the private database of your iCloud account. Only
  encrypted wallet data and the vault's unencrypted header (described
  above) are uploaded. Apple can see how many wallets you have and when
  they changed; Apple cannot read them, and the developer cannot access a
  user's private CloudKit database.
- **Backups**: iCloud Backup of your iPhone includes the encrypted vault
  file unless you turn that off in SafeKey's settings. On the Mac, "Keep an
  encrypted copy in iCloud Drive" places the same encrypted file in your
  iCloud Drive. Backups you export yourself are the same encrypted file.

Apple's handling of iCloud data is governed by Apple's privacy policy.

## 4. Data we share

None. There is nothing to share.

## 5. Your choices

- Turn iCloud sync off at any time; "Stop Syncing and Remove Copy" also
  deletes the iCloud copy.
- Exclude the vault from iCloud Backup in Settings.
- Delete the app to delete everything it stored on the device.
  Self-destruct, if armed, erases the vault after the number of wrong
  passwords you chose.

## 6. Children

SafeKey is not directed at children under 13 and collects no data from
anyone.

## 7. Changes

If this policy changes, the new version will be published with the app
update that introduces the change, with the effective date above updated.

## 8. Contact

[contact email] — Thomann Web Solutions, [postal address if required by
the App Store or Swiss law].
