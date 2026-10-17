import SwiftUI
import WebKit
import UIKit

final class BrowserViewport: UIView {
    let page: WKWebView
    var thumbnail = true { didSet { setNeedsLayout() } }
    var onTouch: (() -> Void)?
    private(set) var touchObserver: PageTouchObserver!
    init(page: WKWebView) {
        self.page = page; super.init(frame: .zero); clipsToBounds = true
        addSubview(page)
        touchObserver = PageTouchObserver { [weak self] in
            guard let self, !self.thumbnail else { return }
            self.onTouch?()
        }
        addGestureRecognizer(touchObserver)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width: CGFloat = thumbnail ? 390 : bounds.width
        let scale = bounds.width / width
        page.transform = .identity
        page.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height / scale)
        page.center = CGPoint(x: bounds.midX, y: bounds.midY)
        page.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

}
/// Observes touches actually delivered to the page hierarchy. Hit testing must
/// stay side-effect free: SwiftUI probes views beneath its preview controls too.
final class PageTouchObserver: UIGestureRecognizer {
    private let onBegan: () -> Void
    init(onBegan: @escaping () -> Void) {
        self.onBegan = onBegan
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onBegan()
        // Never recognize or compete with WebKit's scrolling/tapping gestures.
        state = .failed
    }
}

struct BrowserView: UIViewRepresentable {
    let session: BrowserSession
    let thumbnail: Bool
    func makeUIView(context: Context) -> BrowserViewport { BrowserViewport(page: session.webView) }
    func updateUIView(_ view: BrowserViewport, context: Context) {
        view.thumbnail = thumbnail; view.onTouch = { session.humanInteraction() }
        view.isUserInteractionEnabled = !thumbnail
        view.accessibilityElementsHidden = thumbnail || !session.state.isOpen || session.state.presentation == .hidden
    }
}
