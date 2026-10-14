#if DEBUG
import AppKit
import AVFoundation
import CoreVideo
import SwiftUI
import SafeKeyCore

/// Debug builds only: films the Mac app for the marketing video.
///
/// `SAFEKEY_PROMO_DIR=<dir>`, together with `SAFEKEY_DEMO=1` (the throwaway
/// demo vault) and `SAFEKEY_ALLOW_CAPTURE=1`, sizes the main window, records it
/// to `mac-tour.mov` while stepping through a fixed script — two wallets, a
/// key revealed and hidden, a seed phrase, a chain — then locks, writes stills
/// of the key moments, and quits. Settings are left out: they read the login
/// Keychain, which a differently signed copy of the app cannot do silently. It only ever captures
/// this app's own windows, which needs no screen-recording permission.
@MainActor
enum PromoDirector {
    enum Command {
        case select(SidebarItem)
        case open(String)
        case reveal
        case hide
    }

    static let command = Notification.Name("SafeKeyPromoDirectorCommand")

    static var directory: URL? {
        ProcessInfo.processInfo.environment["SAFEKEY_PROMO_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static var started = false

    static func runIfRequested(model: AppModel) {
        guard let directory, !started else { return }
        started = true
        Task { await run(model: model, directory: directory) }
    }

    private static func send(_ command: Command) {
        NotificationCenter.default.post(name: Self.command, object: command)
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func mark(_ name: String, in directory: URL) {
        let line = String(format: "PROMO_MARK %@ %.3f\n", name, Date().timeIntervalSince1970)
        FileHandle.standardError.write(Data(line.utf8))
        let url = directory.appendingPathComponent("mac-tour.times")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func still(_ window: NSWindow, _ name: String, in directory: URL) {
        guard let image = WindowCapture.image(of: CGWindowID(window.windowNumber)) else { return }
        let url = directory.appendingPathComponent("\(name).png") as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func run(model: AppModel, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("mac-tour.times"))
        while model.session == nil { await wait(0.2) }
        await wait(1.0)
        guard let window = NSApp.windows.filter({ $0.isVisible }).max(by: { $0.frame.width < $1.frame.width }) else {
            FileHandle.standardError.write(Data("[promo] no window\n".utf8)); exit(1)
        }
        window.setFrame(NSRect(x: 160, y: 140, width: 1280, height: 800), display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await wait(1.5)

        let recorder = WindowRecorder(windowID: CGWindowID(window.windowNumber),
                                      url: directory.appendingPathComponent("mac-tour.mov"))
        recorder.start()
        await wait(0.3)
        mark("rec-start", in: directory)
        await wait(1.2)
        still(window, "mac-main", in: directory)

        send(.open("Daily Burner")); mark("open-main", in: directory)
        await wait(2.2)
        send(.open("Airdrop Farm A")); mark("open-defi", in: directory)
        await wait(1.6)
        still(window, "mac-detail-key", in: directory)
        send(.reveal); mark("reveal-key", in: directory)
        await wait(1.0)
        still(window, "mac-detail-revealed", in: directory)
        await wait(1.8)
        send(.hide); mark("hide-key", in: directory)
        await wait(1.4)

        send(.select(.seedPhrases)); mark("seed-list", in: directory)
        await wait(1.4)
        send(.open("Test Wallet")); mark("open-cold", in: directory)
        await wait(1.4)
        send(.reveal); mark("reveal-seed", in: directory)
        await wait(1.0)
        still(window, "mac-seed-revealed", in: directory)
        await wait(2.0)
        send(.hide)
        await wait(1.0)
        send(.select(.chain(.bitcoin))); mark("chain-bitcoin", in: directory)
        await wait(2.0)
        still(window, "mac-chain", in: directory)
        await recorder.stop()
        mark("rec-stop", in: directory)

        model.lock()
        await wait(1.6)
        still(window, "mac-lock", in: directory)
        mark("done", in: directory)
        exit(0)
    }
}

/// `CGWindowListCreateImage` is marked obsolete in the SDK in favour of
/// ScreenCaptureKit, which needs screen-recording permission even for an
/// app's own windows. The function itself still works for them, so it is
/// looked up at runtime.
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let create: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static func image(of windowID: CGWindowID) -> CGImage? {
        // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0; .bestResolution = 1 << 3
        create?(.null, 1 << 3, windowID, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}

/// Records one window to H.264 at up to 30 frames a second. All mutable state
/// lives on its own serial queue.
final class WindowRecorder: @unchecked Sendable {
    private let windowID: CGWindowID
    private let url: URL
    private let queue = DispatchQueue(label: "safekey.promo.recorder", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var startedAt: CFTimeInterval = 0
    private var width = 0
    private var height = 0

    init(windowID: CGWindowID, url: URL) {
        self.windowID = windowID
        self.url = url
    }

    func start() {
        queue.async { self.begin() }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                guard let writer = self.writer else { continuation.resume(); return }
                self.input?.markAsFinished()
                writer.finishWriting { continuation.resume() }
            }
        }
    }

    private func begin() {
        guard let first = WindowCapture.image(of: windowID) else { return }
        width = first.width & ~1
        height = first.height & ~1
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        startedAt = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.frame() }
        self.timer = timer
        timer.resume()
    }

    private func frame() {
        guard let input, input.isReadyForMoreMediaData, let adaptor, let pool = adaptor.pixelBufferPool,
              let image = WindowCapture.image(of: windowID) else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Anchored top-left; an odd pixel row or column falls off the bottom or right.
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = CMTime(seconds: CACurrentMediaTime() - startedAt, preferredTimescale: 600)
        adaptor.append(buffer, withPresentationTime: time)
    }
}
#endif
