#if DEBUG
import Foundation

/// Timing of the way into the vault — a cold launch or a return from the
/// background, then the unlock — printed once so a slow step shows up in the
/// console of a real phone (`devicectl … launch --console`) as well as the
/// simulator. Debug builds only; release builds compile none of it and the
/// call sites are empty.
@MainActor
enum UnlockTrace {
    private static let clock = ContinuousClock()
    private static var start: ContinuousClock.Instant?
    private static var marks: [(String, Duration)] = []

    /// Starts a new timeline. A timeline already running keeps going: a
    /// launch flows into its first unlock on one line.
    static func begin(_ how: String) {
        if start != nil { mark(how); return }
        start = clock.now
        marks = [(how, .zero)]
    }

    static func mark(_ label: String) {
        guard let start else { return }
        marks.append((label, clock.now - start))
    }

    /// Prints everything marked so far. Called a moment after the unlock so
    /// the views' first appearances are on the same line as the model's steps.
    static func flush() {
        guard let start else { return }
        let line = marks.map { "\($0.0)=\(ms($0.1))" }.joined(separator: " ")
        // Both streams, flushed: a `print` to a pipe sits in a block buffer
        // and never reaches a console that is stopped before the app exits,
        // and the device console bridges stdout only.
        let text = "[unlock] \(line) (flushed at \(ms(clock.now - start)))"
        print(text)
        fflush(stdout)
        FileHandle.standardError.write(Data((text + "\n").utf8))
        self.start = nil
        marks = []
    }

    private static func ms(_ d: Duration) -> String {
        let millis = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%.0fms", millis)
    }
}
#else
@MainActor
enum UnlockTrace {
    @inline(__always) static func begin(_ how: String) {}
    @inline(__always) static func mark(_ label: String) {}
    @inline(__always) static func flush() {}
}
#endif
