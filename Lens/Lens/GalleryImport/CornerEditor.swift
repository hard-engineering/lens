import SwiftUI
import UIKit

/// SwiftUI wrapper around CornerEditorView.
struct CornerEditor: View {
    let image: UIImage
    let detectedQuad: DocumentQuad

    @Binding var quad: DocumentQuad
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea(edges: .horizontal)
                CornerEditorRepresentable(image: image, quad: $quad)
                    .padding(16)
            }
            HStack(spacing: 12) {
                Button {
                    quad = detectedQuad
                } label: {
                    Label("Detected", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    quad = .fullImage
                } label: {
                    Label("Full Image", systemImage: "rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .buttonStyle(.bordered)
                Button("Use Photo", action: onConfirm)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }
}

private struct CornerEditorRepresentable: UIViewRepresentable {
    let image: UIImage
    @Binding var quad: DocumentQuad

    func makeUIView(context: Context) -> CornerEditorView {
        let view = CornerEditorView()
        view.image = image
        view.quad = quad
        view.onQuadChanged = { newQuad in
            // Avoid SwiftUI write-during-update by deferring.
            DispatchQueue.main.async { quad = newQuad }
        }
        return view
    }

    func updateUIView(_ uiView: CornerEditorView, context: Context) {
        uiView.image = image
        if uiView.quad != quad {
            uiView.quad = quad
        }
    }
}

/// UIKit corner editor.
///
/// Quad is stored in Vision coordinates (origin lower-left, 0..1). It is converted to
/// view coordinates only for hit-testing and drawing.
final class CornerEditorView: UIView {

    enum Corner: Int, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var image: UIImage? {
        didSet {
            imageView.image = image
            setNeedsLayout()
            overlay.setNeedsDisplay()
        }
    }
    var quad: DocumentQuad = .fullImage {
        didSet { overlay.setNeedsDisplay() }
    }
    var onQuadChanged: ((DocumentQuad) -> Void)?

    private let imageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    private lazy var overlay: OverlayView = {
        let v = OverlayView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.editor = self
        v.backgroundColor = .clear
        return v
    }()

    private lazy var loupe: LoupeView = {
        let v = LoupeView()
        v.isHidden = true
        v.editor = self
        return v
    }()

    private var activeCorner: Corner?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        backgroundColor = .black
        addSubview(imageView)
        addSubview(overlay)
        addSubview(loupe)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.setNeedsDisplay()
        loupe.frame = CGRect(origin: .zero, size: CGSize(width: 140, height: 140))
    }

    // MARK: - Touch handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            activeCorner = nearestCorner(to: location, withinTolerance: 80)
            if activeCorner != nil {
                showLoupe(at: location)
            }
        case .changed:
            guard let corner = activeCorner else { return }
            let clamped = clampToImageRect(location)
            setCornerPoint(corner, viewPoint: clamped)
            showLoupe(at: clamped)
        case .ended, .cancelled, .failed:
            activeCorner = nil
            loupe.isHidden = true
            onQuadChanged?(quad)
        default:
            break
        }
    }

    private func nearestCorner(to point: CGPoint, withinTolerance tolerance: CGFloat) -> Corner? {
        var best: (Corner, CGFloat)?
        for corner in Corner.allCases {
            let cp = viewPoint(for: corner)
            let d = hypot(cp.x - point.x, cp.y - point.y)
            if d <= tolerance {
                if best == nil || d < best!.1 {
                    best = (corner, d)
                }
            }
        }
        return best?.0
    }

    private func showLoupe(at point: CGPoint) {
        loupe.isHidden = false
        let offset: CGFloat = 90
        var center = CGPoint(x: point.x, y: point.y - offset)
        if center.y - loupe.bounds.height / 2 < 0 {
            center.y = point.y + offset
        }
        loupe.center = center
        loupe.focusPoint = point
        loupe.setNeedsDisplay()
    }

    // MARK: - Coordinate conversion

    /// The on-screen frame of the displayed image inside `imageView` (aspect-fit).
    func imageRect() -> CGRect {
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let bounds = imageView.bounds
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
            .offsetBy(dx: imageView.frame.origin.x, dy: imageView.frame.origin.y)
    }

    /// Convert Vision-space normalized point (origin lower-left) to view coords (origin upper-left).
    func viewPoint(for normalized: CGPoint) -> CGPoint {
        let rect = imageRect()
        return CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + (1 - normalized.y) * rect.height
        )
    }

    func viewPoint(for corner: Corner) -> CGPoint {
        viewPoint(for: cornerPoint(corner))
    }

    /// Convert view coords back to Vision-space normalized point.
    func normalizedPoint(forView point: CGPoint) -> CGPoint {
        let rect = imageRect()
        let nx = (point.x - rect.minX) / max(rect.width, 1)
        let ny = 1 - (point.y - rect.minY) / max(rect.height, 1)
        return CGPoint(x: clamp01(nx), y: clamp01(ny))
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }

    private func clampToImageRect(_ point: CGPoint) -> CGPoint {
        let r = imageRect()
        return CGPoint(x: min(max(point.x, r.minX), r.maxX), y: min(max(point.y, r.minY), r.maxY))
    }

    func cornerPoint(_ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: return quad.topLeft
        case .topRight: return quad.topRight
        case .bottomLeft: return quad.bottomLeft
        case .bottomRight: return quad.bottomRight
        }
    }

    private func setCornerPoint(_ corner: Corner, viewPoint: CGPoint) {
        let p = normalizedPoint(forView: viewPoint)
        switch corner {
        case .topLeft: quad.topLeft = p
        case .topRight: quad.topRight = p
        case .bottomLeft: quad.bottomLeft = p
        case .bottomRight: quad.bottomRight = p
        }
    }

    /// Overlay layer that draws the quad outline and four corner handles.
    final class OverlayView: UIView {
        weak var editor: CornerEditorView?

        override func draw(_ rect: CGRect) {
            guard let editor = editor, let ctx = UIGraphicsGetCurrentContext() else { return }

            let tl = editor.viewPoint(for: .topLeft)
            let tr = editor.viewPoint(for: .topRight)
            let br = editor.viewPoint(for: .bottomRight)
            let bl = editor.viewPoint(for: .bottomLeft)

            // Shade outside the quad
            ctx.setFillColor(UIColor(white: 0, alpha: 0.45).cgColor)
            ctx.fill(bounds)
            ctx.setBlendMode(.destinationOut)
            ctx.beginPath()
            ctx.move(to: tl)
            ctx.addLine(to: tr)
            ctx.addLine(to: br)
            ctx.addLine(to: bl)
            ctx.closePath()
            ctx.fillPath()
            ctx.setBlendMode(.normal)

            // Quad outline
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(2)
            ctx.beginPath()
            ctx.move(to: tl)
            ctx.addLine(to: tr)
            ctx.addLine(to: br)
            ctx.addLine(to: bl)
            ctx.closePath()
            ctx.strokePath()

            // Corner handles (44pt outer ring, 22pt inner)
            for point in [tl, tr, bl, br] {
                let outer = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
                let inner = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
                ctx.setStrokeColor(UIColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: outer)
                ctx.setFillColor(UIColor.systemYellow.cgColor)
                ctx.fillEllipse(in: inner)
            }
        }
    }

    /// Magnifier loupe. Re-draws the source image region around the focus point at 2x scale.
    final class LoupeView: UIView {
        weak var editor: CornerEditorView?
        var focusPoint: CGPoint = .zero {
            didSet { setNeedsDisplay() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            layer.cornerRadius = 70
            layer.masksToBounds = true
            layer.borderColor = UIColor.white.cgColor
            layer.borderWidth = 2
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            backgroundColor = .clear
            layer.cornerRadius = 70
            layer.masksToBounds = true
            layer.borderColor = UIColor.white.cgColor
            layer.borderWidth = 2
        }

        override func draw(_ rect: CGRect) {
            guard let editor = editor, let image = editor.image, let ctx = UIGraphicsGetCurrentContext() else { return }
            let imageRect = editor.imageRect()
            let zoom: CGFloat = 2.0

            // Background
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(rect)

            // Compute the on-screen rect of the image to translate into loupe coordinates.
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -focusPoint.x, y: -focusPoint.y)
            image.draw(in: imageRect)
            ctx.restoreGState()

            // Crosshair at center
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: rect.midX - 10, y: rect.midY))
            ctx.addLine(to: CGPoint(x: rect.midX + 10, y: rect.midY))
            ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - 10))
            ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 10))
            ctx.strokePath()
        }
    }
}
