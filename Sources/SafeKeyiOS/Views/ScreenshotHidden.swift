import SwiftUI
import UIKit

/// Renders its content on the layer iOS uses for secure text entry, which a
/// screenshot, a screen recording, mirroring and AirPlay all leave blank —
/// the way the Passwords app's password row comes out empty in a screenshot.
///
/// Public API only: a secure `UITextField` is created, its rendering canvas
/// is adopted as the host, and the content lives inside that canvas. The
/// protection is a property of the canvas's layer, so it survives leaving
/// the field. If a future iOS reshapes that hierarchy the canvas is simply
/// not found and the content renders normally — worse privacy, never a
/// broken screen.
struct ScreenshotHidden<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> SecureCanvasHost<Content> {
        SecureCanvasHost(rootView: content())
    }

    func updateUIView(_ view: SecureCanvasHost<Content>, context: Context) {
        view.rootView = content()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SecureCanvasHost<Content>, context: Context) -> CGSize? {
        uiView.size(fitting: proposal)
    }
}

final class SecureCanvasHost<Content: View>: UIView {
    private let field = UITextField()
    private let host: UIHostingController<Content>

    var rootView: Content {
        get { host.rootView }
        set {
            host.rootView = newValue
            host.view.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        // Let the hosted SwiftUI content drive its own size, so the row and
        // what it draws change together.
        host.sizingOptions = [.intrinsicContentSize]

        // The flag has to be on before the canvas is looked up: it is what
        // makes the field build the secure canvas in the first place.
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false

        let canvas = Self.filming ? nil : field.subviews.first { String(describing: type(of: $0)).contains("Canvas") }
        let container: UIView
        if let canvas {
            canvas.subviews.forEach { $0.removeFromSuperview() }
            canvas.isUserInteractionEnabled = true
            container = canvas
            pin(canvas, into: self)
        } else {
            container = self
        }
        pin(host.view, into: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `--promo-visible-secrets` (debug builds only) draws the content
    /// normally, so a screen recording made for marketing can show what the
    /// person holding the phone sees. Nothing else about the reveal changes.
    private static var filming: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--promo-visible-secrets")
        #else
        false
        #endif
    }

    /// Whether the content is actually on the secure canvas, for tests.
    var isProtected: Bool {
        host.view.superview !== self
    }

    func size(fitting proposal: ProposedViewSize) -> CGSize {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        return host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
    }

    override var intrinsicContentSize: CGSize {
        host.sizeThatFits(in: CGSize(width: bounds.width > 0 ? bounds.width : UIView.layoutFittingExpandedSize.width,
                                     height: UIView.layoutFittingExpandedSize.height))
    }

    private func pin(_ view: UIView, into parent: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}
