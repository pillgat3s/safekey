import AppKit
import SafeKeyCore

/// Locks the vault on sleep, screen lock, and app inactivity.
/// Inactivity means "no user events in *this app*" — switching away stops the
/// event stream, so time spent elsewhere counts toward the timeout.
@MainActor
final class AutoLockService {
    private var eventMonitor: Any?
    private var checkTimer: Timer?
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var distributedObserver: (any NSObjectProtocol)?
    private var lastActivity = Date()
    private var settings: VaultSettings?
    private var onLock: (() -> Void)?

    func start(settings: VaultSettings, onLock: @escaping () -> Void) {
        stop()
        self.settings = settings
        self.onLock = onLock
        lastActivity = Date()

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = Date() }
            return event
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if settings.lockOnSleep {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockNow() }
            })
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockNow() }
            })
        }
        if settings.lockOnScreenLock {
            distributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockNow() }
            }
        }

        if let seconds = settings.autoLockSeconds, seconds > 0 {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let limit = self.settings?.autoLockSeconds else { return }
                    if Date().timeIntervalSince(self.lastActivity) >= Double(limit) {
                        self.lockNow()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            checkTimer = timer
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        checkTimer?.invalidate()
        checkTimer = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers = []
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
        onLock = nil
    }

    private func lockNow() {
        let callback = onLock
        stop()
        callback?()
    }
}
