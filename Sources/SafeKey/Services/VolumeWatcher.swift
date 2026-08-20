import AppKit
import Observation
import SafeKeyCore

/// Live "is the security key inserted?" state for the unlock screen. Reacts
/// to mount/unmount notifications; unlock attempts always re-poll the
/// provider directly (slow USB mounts can beat the notification).
@MainActor
@Observable
final class VolumeWatcher {
    private(set) var deviceKeyPresent = false
    private var policy: UnlockPolicy?
    private var observers: [any NSObjectProtocol] = []
    private let provider: any DeviceKeyProvider

    init(provider: any DeviceKeyProvider = VolumeDeviceKeyProvider()) {
        self.provider = provider
    }

    func start(policy: UnlockPolicy) {
        stop()
        self.policy = policy
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
        policy = nil
        deviceKeyPresent = false
    }

    func refresh() {
        guard let policy else {
            deviceKeyPresent = false
            return
        }
        deviceKeyPresent = provider.locateDeviceKey(policy: policy) != nil
    }

    /// Fresh poll — used at the moment of an unlock attempt.
    func currentDeviceKey() -> Data? {
        guard let policy else { return nil }
        return provider.locateDeviceKey(policy: policy)
    }
}
