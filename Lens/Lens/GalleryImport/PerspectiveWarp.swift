import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum PerspectiveWarp {

    /// Apply a CIPerspectiveCorrection using a normalized quad expressed in Vision
    /// coordinates (lower-left origin, 0..1). Returns nil only on failure.
    static func apply(to image: UIImage, quad: DocumentQuad) -> UIImage? {
        let upright = image.normalizedUpright()
        guard let cg = upright.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ci
        // CIPerspectiveCorrection expects pixel coordinates with origin at bottom-left,
        // matching Vision's normalized convention. Multiply by extent.
        filter.topLeft = CGPoint(x: quad.topLeft.x * extent.width, y: quad.topLeft.y * extent.height)
        filter.topRight = CGPoint(x: quad.topRight.x * extent.width, y: quad.topRight.y * extent.height)
        filter.bottomLeft = CGPoint(x: quad.bottomLeft.x * extent.width, y: quad.bottomLeft.y * extent.height)
        filter.bottomRight = CGPoint(x: quad.bottomRight.x * extent.width, y: quad.bottomRight.y * extent.height)

        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgOut = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgOut, scale: image.scale, orientation: .up)
    }
}

extension UIImage {
    /// Returns a copy whose underlying CGImage matches the .up orientation.
    /// Necessary before feeding to CoreImage because CIPerspectiveCorrection
    /// operates in the CGImage coordinate space and ignores UIImage.imageOrientation.
    func normalizedUpright() -> UIImage {
        if imageOrientation == .up { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
