import AppKit

/// Copies secrets to the clipboard with the conventional "concealed" marker
/// (so clipboard managers skip them) and clears them after a delay — but only
/// if the user hasn't copied something else in the meantime.
@MainActor
final class ClipboardGuard {
    static let shared = ClipboardGuard()

    /// org.nspasteboard.org convention understood by clipboard managers.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private var lastChangeCount: Int?
    private var clearTask: Task<Void, Never>?

    private init() {}

    func copy(_ secret: String, clearAfter seconds: Int?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("1", forType: Self.concealedType)
        lastChangeCount = pasteboard.changeCount

        clearTask?.cancel()
        guard let seconds, seconds > 0 else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clearIfStillOurs()
        }
    }

    func clearIfStillOurs() {
        let pasteboard = NSPasteboard.general
        // Don't stomp something the user copied after us.
        guard pasteboard.changeCount == lastChangeCount else { return }
        pasteboard.clearContents()
        lastChangeCount = nil
    }
}
