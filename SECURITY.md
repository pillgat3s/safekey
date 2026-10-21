# Security

SafeKey holds wallet secrets, so a flaw in it matters more than in most apps.
If you find one, please tell us before you tell anyone else.

## Reporting a vulnerability

Email **help@tws.sh** with "SafeKey security" in the subject. Include what you
found, how to reproduce it, and which version and platform you were on. You
will get a reply from the person who wrote the code, normally within a few
days; this is a one-person project, so please allow for that.

We ask for coordinated disclosure: give us a reasonable window to ship a fix
before publishing details. There is no bug bounty programme.

Please never send a real seed phrase, private key or master password, yours or
anyone else's, in a report. Use invented values.

## What is in scope

Anything that would let someone other than the vault's owner read a secret,
weaken the encryption, bypass the lock, forge or corrupt a vault file, trigger
self-destruct against the owner's will, or make a secret appear in a
screenshot, a log, the clipboard beyond its lifetime, or any network request.
The code that matters most lives in `Sources/SafeKeyCore`.

## What the design assumes

The threat model, the storage map and the honest limits are written up in
[marketing/launch/security-review.md](marketing/launch/security-review.md)
and in the README's security section. In short: the vault is only as strong
as the master password and the slow key derivation in front of it; an attacker
who copies the vault file can try passwords offline forever; nothing in the app
can stop a camera pointed at the screen.

## Verifying a release

Mac downloads ship with a `.sha256` file; `shasum -a 256 -c` checks the DMG,
and `spctl --assess --type execute SafeKey.app` confirms the notarization.
iOS builds come only through TestFlight and the App Store, which verify their
own signatures. What the published code cannot prove is that a given App Store
binary was built from it; iOS does not allow reproducible builds. Read the code
to see what the app does, and treat the signed builds as our word that it is
what shipped.
