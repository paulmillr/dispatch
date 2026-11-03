import SwiftUI
import UIKit

/// An image fitted to its space (less `inset` on each side) that zooms with a pinch, pans while zoomed, and toggles a
/// closer look with a double tap at the tapped point; `tap` (when given) is a single tap's, after a double tap failed.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var inset: CGFloat = 0
    var tap: (() -> Void)?

    func makeUIView(context: Context) -> ZoomingImageView { ZoomingImageView() }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        view.inset = inset
        view.image = image
        view.tap = tap
    }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let doubleTap = UITapGestureRecognizer()
    private let singleTap = UITapGestureRecognizer()
    /// The bounds the image was last fitted to: a new size (rotation, split view) fits it again.
    private var fitted: CGSize?

    var image: UIImage? {
        didSet { if image !== oldValue { imageView.image = image; fitted = nil; setNeedsLayout() } }
    }
    var inset: CGFloat = 0 {
        didSet { if inset != oldValue { fitted = nil; setNeedsLayout() } }
    }
    var tap: (() -> Void)? {
        didSet { singleTap.isEnabled = tap != nil }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        addSubview(imageView)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(doubleTapped))
        addGestureRecognizer(doubleTap)
        singleTap.require(toFail: doubleTap)
        singleTap.addTarget(self, action: #selector(singleTapped))
        singleTap.isEnabled = false
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fitted != bounds.size { fit() }
    }

    /// At zoom 1 the image fits the bounds less the inset; zooming goes up to 3 times its own pixels on screen, at least 4.
    private func fit() {
        fitted = bounds.size
        minimumZoomScale = 1
        zoomScale = 1
        let room = bounds.insetBy(dx: inset, dy: inset).size
        guard let image, room.width > 0, room.height > 0, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = .zero
            contentSize = .zero
            return
        }
        let scale = min(room.width / image.size.width, room.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        let screen = window?.screen.scale ?? traitCollection.displayScale
        let pixels = image.size.width * image.scale / (size.width * max(screen, 1))
        maximumZoomScale = max(4, pixels * 3)
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    /// Smaller than the bounds, the image sits in their middle.
    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale = min(maximumZoomScale, 2.5)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
             animated: true)
    }

    @objc private func singleTapped() { tap?() }
}
