# SafeKey Vault Format v1

The complete on-disk specification, written so a non-Apple client (a future
Windows port) can read and write the same vault. Only standard primitives are
used: PBKDF2-HMAC-SHA256, AES-256-GCM, HKDF-SHA256, JSON, base64.

## File location

- macOS: `~/Library/Application Support/SafeKey/vault.safekey`, mode `0600`
- Sidecar: `state.dat` in the same directory (failed-attempt mirror, not secret)

## Container layout

Little-endian, single file:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | Magic, ASCII `SFKVLT01` |
| 8 | 2 | Container version, `UInt16` = 1 |
| 10 | 4 | Header length `H`, `UInt32` |
| 14 | H | Header JSON, UTF-8, **plaintext but authenticated** |
| 14+H | rest | AES-256-GCM sealed payload: 12-byte nonce ‖ ciphertext ‖ 16-byte tag |

## Header JSON

```json
{
  "formatVersion": 1,
  "vaultID": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
  "createdAt": "2026-07-30T11:22:33Z",
  "kdf": {
    "algorithm": "pbkdf2-hmac-sha256",
    "iterations": 812000,
    "salt": "<base64, 32 bytes>"
  },
  "wrappedDEK": "<base64: 12-byte nonce ‖ ciphertext ‖ 16-byte tag>",
  "selfDestruct": { "enabled": false, "maxAttempts": 5 },
  "unlockPolicy": {
    "requiresDevice": false,
    "volumeUUID": null,
    "volumeName": null,
    "keyFileRelPath": null
  }
}
```

Encoding rules (must match byte-for-byte, since these bytes are authenticated):
JSON with **sorted keys**, dates as **ISO 8601** (`2026-07-30T11:22:33Z`, second
precision, UTC), `Data` fields as **base64**.

## Key hierarchy

```
password ──PBKDF2-HMAC-SHA256(salt, iterations)──► KEK (32 bytes)
                                                    │
device key (optional, 32 bytes from USB) ───────────┤
                                                    ▼
                        HKDF-SHA256 (only if unlockPolicy.requiresDevice)
                                                    │
                                                    ▼
                              KEK' ──AES-256-GCM──► wrappedDEK
                                                    │
                                                    ▼
                                       DEK (32 bytes, random)
                                                    │
                                                    ▼
                              AES-256-GCM(payload, AAD = header bytes)
```

- **DEK**: random 256-bit key encrypting the payload. A **password change
  re-wraps the same DEK** (cheap, and the Touch ID Keychain copy stays valid).
  An **unlock-policy change rotates it**: enabling or disabling the USB factor
  generates a fresh DEK and re-encrypts the payload under it.

  Rotation on policy change is required, not an optimization. The AAD binds the
  header to a given DEK; it does not bind the DEK to a policy. Without rotation,
  anyone holding a pre-2FA copy of the container (Time Machine, a synced folder,
  an old disk image) plus the password could recover that DEK from the old copy
  and open the current two-factor container with it, so enabling the second
  factor would protect nothing going forward. A rotated DEK never existed in any
  earlier copy. Any stored biometric copy of the DEK must be refreshed after a
  rotation, or removed.
- **KEK**: `PBKDF2-HMAC-SHA256(password, salt, iterations, dkLen = 32)`.
  Iterations are calibrated at creation to ≈250 ms on the creating machine,
  never below 600,000 (OWASP floor).
- **KEK′ (two-factor)**: when `unlockPolicy.requiresDevice` is true,
  ```
  KEK' = HKDF-SHA256(
      IKM  = KEK ‖ deviceKey,       // 64 bytes, concatenated
      salt = kdf.salt,               // the same 32-byte salt
      info = "safekey-2f-v1",        // ASCII, no NUL
      L    = 32)
  ```
  and `wrappedDEK` is sealed under KEK′. Without the device key bytes the DEK
  cannot be unwrapped at any password.

## AAD rule (important)

The payload is sealed with **additional authenticated data equal to the first
`14 + H` bytes of the file** — magic, version, header length, and the exact
header JSON bytes as stored.

Consequences:
- Every header change must be made while unlocked and followed by re-sealing
  the payload.
- The failed-attempt counter therefore **cannot** live in the header.

### What the AAD does *not* protect (read this before trusting the header)

The AAD is verified inside `openPayload`, which runs **after** the DEK has been
unwrapped. On a failed unlock the DEK is never recovered, so **nothing in the
header has been authenticated at that point**. A header edit that also breaks
KEK derivation (flipping a salt byte, changing the iteration count) surfaces as
`wrongPassword`, not `tampered` — the tag never gets a chance to fail.

Therefore: **no security decision may be made from a freshly parsed header on
the failure path.** In particular, self-destruct policy and the attempt counter
must come from the out-of-band anchor described below. Reading them from the
header allowed an attacker with only write access to arm self-destruct, corrupt
the salt, and have the owner's own correct password erase the vault.

## Trust anchor (sidecar, not part of the container)

`anchor.dat` next to the vault, plus a Keychain item, record what the vault
looked like at the last **successful** unlock:

```json
{
  "vaultID": "…",
  "selfDestruct": { "enabled": true, "maxAttempts": 5 },
  "headerDigest": "<base64 SHA-256 of the container prefix [0, 14+H)>",
  "failedAttempts": 2
}
```

Rules:
- Written on every successful unlock and every save; the counter resets on
  success.
- The Keychain copy is authoritative. The file mirror carries an
  `HMAC-SHA256` under a key stored only in the Keychain, so an attacker with
  filesystem access cannot forge a high attempt count to force a wipe. An
  unverifiable mirror is ignored, not trusted.
- Effective attempt count is the higher of the two, so clearing one store does
  not reset the anti-guessing clock.
- **Destruction requires `headerDigest` to match the file on disk.** A modified
  header disables self-destruct and raises a tamper warning instead.
- **No anchor means no destruction.** A vault that has never been opened on
  this machine cannot self-destruct. Failing toward keeping data is always the
  safer direction.
- The counter is keyed to a fixed account, never to `vaultID` — that field is
  attacker-rewritable, and keying on it let an attacker reset the counter
  before every guess.

## Payload JSON (plaintext, before sealing)

```json
{
  "schemaVersion": 1,
  "entries": [
    {
      "id": "UUID",
      "name": "Main ETH Wallet",
      "chain": { "ethereum": {} },
      "kind": { "seedPhrase": { "wordCount": 12 } },
      "secret": "abandon ability able …",
      "publicAddress": "0x…",
      "notes": "",
      "tags": ["hot"],
      "favorite": true,
      "createdAt": "2026-01-04T09:00:00Z",
      "modifiedAt": "2026-07-30T10:15:00Z"
    }
  ],
  "settings": {
    "autoLockSeconds": 300,
    "lockOnSleep": true,
    "lockOnScreenLock": true,
    "clipboardClearSeconds": 30,
    "revealPolicy": { "never": {} },
    "defaultChain": { "ethereum": {} },
    "sortOrder": "dateModified"
  }
}
```

`chain`, `kind`, and `revealPolicy` use Swift's default enum-with-payload
encoding (single-key object named after the case). A port should mirror this
shape exactly, or bump `schemaVersion` and migrate.

## Operations

**Create**: pick salt + iterations → derive KEK → generate DEK → wrap DEK →
build header → seal payload with header-prefix AAD → write.

**Unlock (password)**: parse container → derive KEK (+HKDF if device required)
→ `AES-GCM open(wrappedDEK)`; failure here **is** the wrong-password signal (no
separate verifier exists) → `AES-GCM open(payload, aad: prefix)`.

**Unlock (biometric)**: read the DEK copy from the Keychain, skip the KDF, open
the payload directly. When the device factor is on, the Keychain blob is
`AES-GCM(deviceKey, DEK)` rather than the raw DEK.

**Save**: re-encode header → recompute prefix → seal payload with a **fresh
random nonce** → write atomically (temp file in the same directory, fsync,
rename).

**Change password**: unlock → new random salt → derive new KEK → re-wrap the
same DEK → re-seal payload. Old password stops working; DEK and biometric copy
survive.

**Enable/disable the device factor**: unlock with current credentials → **new
random DEK** → new salt → derive KEK (with or without HKDF) → wrap the new DEK →
re-seal the payload under it → refresh or remove the biometric copy.

**Self-destruct**: delete all Keychain items for the vault **in both Keychain
domains** (the biometric DEK copy lives in the data-protection keychain; a query
without `kSecUseDataProtectionKeychain` cannot match it, and missing it would
leave a usable, biometry-gated copy of the vault key behind), clear the
biometric strategy markers from UserDefaults, overwrite the container with
random bytes (best effort — APFS copy-on-write may preserve old blocks), delete
the directory. The real deletion is cryptographic: every wrapped copy of the DEK
is gone. The operation reports failure rather than silently doing nothing.

## Keychain items (macOS)

Service `com.andri.safekey`, all `ThisDeviceOnly`:

| Account | Contents | Protection |
|---|---|---|
| `dek.bio.<vaultID>` | DEK, or `AES-GCM(deviceKey, DEK)` | `SecAccessControl(.biometryCurrentSet)` + `WhenUnlockedThisDeviceOnly`; falls back to an `LAContext`-gated plain item on ad-hoc signed builds |
| `anchor.current` | Trust anchor JSON (see above) | `AfterFirstUnlockThisDeviceOnly` |
| `anchor.mackey` | 32 bytes, HMAC key for the file mirror | `AfterFirstUnlockThisDeviceOnly` |

Every Keychain item is a **cache**. Password unlock must always work with zero
Keychain reads.

## USB device key

Default path on the chosen volume: `.safekey/device.key`, exactly 32 random
bytes, no header. `volumeUUID`/`volumeName` in the policy are detection hints
for the UI only — a client must accept the key file found on any mounted
volume. The bytes are the security boundary, not the volume identity.

`keyFileRelPath` arrives from the unauthenticated header, so it must be treated
as hostile input: only a plain relative path under the volume root is accepted.
Absolute paths, `.`, `..`, and anything that resolves outside the volume are
rejected. Joining it unchecked would give a tampered vault an arbitrary-path
read or write on a non-sandboxed client.

## Sidecar files

| File | Purpose | Notes |
|---|---|---|
| `vault.safekey` | the container | 0600, written atomically via a unique `O_EXCL \| O_NOFOLLOW` temp file + rename |
| `anchor.dat` | trust anchor mirror | 0600, HMAC-authenticated |
