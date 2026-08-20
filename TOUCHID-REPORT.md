# Touch ID unlock does not trigger — SafeKey (macOS 26, SwiftUI)

## Environment

- macOS 26.2, Xcode 26.6, Swift 6.3, SwiftUI, no sandbox
- App signed with a real **Apple Development** certificate (Team `RR9A8973M8`), installed in `/Applications`
- Mac has working Touch ID (Magic Keyboard)

## Symptom

The lock screen shows an app icon with a Touch ID badge. Touch ID never unlocks the vault.
Password unlock works fine.

## THE KEY EVIDENCE

The app logs every stage to `~/Library/Application Support/SafeKey/biometric-log.txt`.
After many user attempts, the log contains **only** these lines:

```
22:26:01  lock screen shown — badge VISIBLE
3:26:40   lock screen shown — badge VISIBLE
3:27:55   lock screen shown — badge VISIBLE
3:28:08   lock screen shown — badge HIDDEN
3:28:14   lock screen shown — badge HIDDEN
3:28:31   lock screen shown — badge VISIBLE
```

`unlockWithTouchID()` logs `"touch ID requested"` as its **first statement**, before any
guard. **That line never appears.** So the function is never entered. This is not a
Keychain, key-material, or LAContext problem — the trigger never fires.

Two candidate explanations:

1. The SwiftUI `Button` is rendered but never receives the click.
2. The user is **touching the Touch ID sensor** rather than clicking the badge. On macOS
   the sensor is only armed while an `LAContext.evaluatePolicy` call is in flight, and
   there is currently no automatic prompt on appear — so touching the sensor does nothing.

(2) is strongly suspected but unconfirmed.

Note also lines 4–5: badge `HIDDEN` twice. `canUnlockWithBiometrics` is cached state and
was not always refreshed — a `lock()` path that failed to refresh it has since been fixed,
but the flag may still go stale on some paths.

## Everything below the trigger is VERIFIED WORKING

A built-in diagnostic (`SAFEKEY_BIO_DIAG=1`) run against the **real** vault reports:

```
canEvaluatePolicy(biometrics) = true
biometryType = 1                        (LABiometryType.touchID)
canEvaluatePolicy(deviceOwner) = true
vaultID = 12135D61-F04B-407D-9DDB-FDAED7CD2DFF
marker strategy   = laContextGated
resolved strategy = laContextGated
isEnrolled = true
→ badge would SHOW
REAL key silent read → OSStatus 0, 32 bytes      ✅
lookup dataProtection=false → OSStatus 0         (item present, legacy keychain)
lookup dataProtection=true  → OSStatus -25300    (errSecItemNotFound)
plain keychain write+read = OK
plain keychain delete = OK
enable(test) → strategy laContextGated
isEnrolled(test) = true
silent DATA read of fresh item → OSStatus 0      (no ACL prompt)
```

So: biometrics available, key enrolled, 32-byte key reads back with **no prompt**.

## Relevant code

### The badge (SwiftUI) — `UnlockView.swift`

```swift
private var icon: some View {
    ZStack(alignment: .bottomTrailing) {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: 96, height: 96)
            .padding(.trailing, 12)
            .padding(.bottom, 10)

        if biometricsAvailable {
            Button(action: unlockWithTouchID) {
                Image(systemName: "touchid")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color(red: 0.98, green: 0.15, blue: 0.42))
                    .padding(5)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isUnlocking)
        }
    }
    .fixedSize()
}
```

`unlockWithTouchID()` begins with:

```swift
private func unlockWithTouchID() {
    guard !isUnlocking else {
        BiometricDiagnosticLog.record("press ignored — already authenticating")
        return
    }
    BiometricDiagnosticLog.record("touch ID requested (badge visible: \(biometricsAvailable))")
    ...
}
```

Neither log line ever appears.

### Enclosing view hierarchy

```swift
var body: some View {
    ZStack {
        VisualEffectBackground(material: .underWindowBackground)   // NSViewRepresentable
            .ignoresSafeArea()

        VStack(spacing: 0) {
            icon.padding(.bottom, 20)
            Text("\(appName) Is Locked")
            Text(subtitle)
            passwordField.padding(.top, 22)
            status.padding(.top, 14)
        }
        .padding(40)
        .offset(y: 20)
    }
    .chromelessWindow(compactSize: NSSize(width: 640, height: 560), translucent: true)
    .onAppear { passwordFocused = true; /* logs badge visibility */ }
}
```

`chromelessWindow` applies `.background(WindowChrome(...))` (an `NSViewRepresentable` that
sets `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `isOpaque = false`,
`backgroundColor = .clear`, and resizes the window), plus
`.toolbar(removing: .title)` and `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`.

Also relevant: `RootView` applies `.protectedWindow(blocksScreenCapture: !isLocked)`, which
sets `NSWindow.sharingType`. On the lock screen it is `.readOnly`; elsewhere `.none`.

### Authentication path (only reached if the trigger fires)

```swift
@MainActor
private func evaluateBiometrics(reason: String, context suppliedContext: LAContext? = nil) async throws {
    let context = suppliedContext ?? LAContext()
    let success = try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: reason
    )
    guard success else { throw BiometricError.failed }
}
```

Then a plain keychain read of `dek.bio.<vaultID>` (service `com.andri.safekey`), giving the
32-byte DEK, which decrypts the vault.

## What has already been tried (and did not fix it)

1. Stable code signing (Apple Development cert) instead of ad-hoc — fixed recurring
   login-keychain password prompts, did not fix the trigger.
2. Keychain item written with a self-trusting ACL via `SecAccessCreate` +
   `SecTrustedApplicationCreateFromPath` — verified no prompt on read.
3. `isEnrolled` no longer depends on the UserDefaults marker; the stored key is the source
   of truth and the marker is repaired from whichever keychain domain holds the item.
4. Failed reads no longer delete the enrolment (only `errSecItemNotFound` does).
5. `evaluateBiometrics` moved to `@MainActor`.
6. `NSApp.activate()` + `makeKeyAndOrderFront` before evaluating.
7. Badge moved out of `.overlay { }.offset(...)` into a `ZStack` sized to contain it,
   because SwiftUI draws content outside a parent's bounds but does not hit-test it.
8. `LAAuthenticationView` (`LocalAuthenticationEmbeddedUI`) tried for an in-window prompt —
   reverted; it rendered nothing and swallowed clicks as a plain `NSView`.
9. Automatic prompt on appear was **removed** earlier because auto-lock re-showed the lock
   screen on a timer and re-prompted every few minutes.

## Questions

1. Why would a SwiftUI `Button` inside a `ZStack`, in a window whose content view is layered
   over an `NSVisualEffectView` (`blendingMode = .behindWindow`) in a non-opaque, clear
   background, transparent-titlebar window, never fire its action? Does
   `NSVisualEffectView`, `NSWindow.isOpaque = false`, or `sharingType` affect SwiftUI hit
   testing?

2. On macOS, is there any way to keep the Touch ID sensor **armed** while a lock screen is
   displayed, so a sensor touch authenticates without the user first clicking a control —
   the way Apple's Passwords app behaves — given that `LAContext.evaluatePolicy` shows a
   system panel for the whole time it is in flight?

3. If the answer to (2) is "call `evaluatePolicy` on appear and leave it pending", what is
   the correct way to avoid re-prompting each time an inactivity timer re-locks the app
   while it is in the background?
