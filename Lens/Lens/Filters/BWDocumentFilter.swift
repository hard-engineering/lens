import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Black-and-white document filter implementing spec §7:
///   Stage 1 — Shadow normalization: divide luminance by a large-radius box-blur
///   estimate of local background illumination.
///   Stage 2 — Sauvola adaptive threshold: t = mean * (1 + k * (sigma/R - 1))
///
/// All math uses explicit CIColorKernels in normalized 0..1 luminance space —
/// blend-mode filters (CIDivideBlendMode etc.) work in gamma-corrected sRGB and
/// were producing all-white output when chained.
///
/// Thread safety: kernels are initialized eagerly (no `lazy var`, which is not
/// thread-safe under concurrent first access) and `apply` is serialized via an
/// internal lock. Multiple `Task.detached` consumers can call into the same
/// instance and the last one will no longer hang on CIContext contention.
final class BWDocumentFilter {

    private let ciContext: CIContext
    private let normalizeKernel: CIColorKernel?
    private let squareKernel: CIColorKernel?
    private let thresholdKernel: CIColorKernel?
    private let lock = NSLock()

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpaceCreateDeviceGray(),
            ])
        } else {
            self.ciContext = CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpaceCreateDeviceGray(),
            ])
        }
        self.normalizeKernel = CIColorKernel(source: """
        kernel vec4 shadowNormalize(__sample lum, __sample bg) {
            float v = clamp(lum.r / max(bg.r, 0.05), 0.0, 1.0);
            return vec4(v, v, v, 1.0);
        }
        """)
        self.squareKernel = CIColorKernel(source: """
        kernel vec4 squarePixel(__sample x) {
            float v = x.r * x.r;
            return vec4(v, v, v, 1.0);
        }
        """)
        self.thresholdKernel = CIColorKernel(source: """
        kernel vec4 sauvola(__sample lum, __sample mean, __sample meanSq, float k, float R) {
            float m = mean.r;
            float s2 = max(meanSq.r - m * m, 0.0);
            float s = sqrt(s2);
            float t = m * (1.0 + k * (s / R - 1.0));
            float v = lum.r < t ? 0.0 : 1.0;
            return vec4(v, v, v, 1.0);
        }
        """)
    }

    /// Apply the full pipeline. Returns the original image if any step fails.
    /// Serialized — only one filter pipeline runs at a time per instance.
    func apply(to image: UIImage) -> UIImage {
        lock.lock()
        defer { lock.unlock() }

        guard let cgInput = cgImage(from: image) else { return image }
        let ci = CIImage(cgImage: cgInput)
        let extent = ci.extent

        // Stage 0: luminance (grayscale)
        let lumFilter = CIFilter.colorControls()
        lumFilter.inputImage = ci
        lumFilter.saturation = 0.0
        guard let lum = lumFilter.outputImage?.cropped(to: extent) else { return image }

        // Stage 1: shadow normalization — large box-blur background estimate, then explicit divide.
        let shortSide = min(extent.width, extent.height)
        let shadowRadius = max(8.0, shortSide / 20.0)
        guard let background = boxBlur(lum, radius: shadowRadius, extent: extent),
              let normalizeKernel,
              let normalized = normalizeKernel.apply(extent: extent, arguments: [lum, background])
        else { return image }

        // Stage 2: Sauvola — local mean and local mean-of-squares.
        let sauvolaRadius = max(7.0, shortSide / 140.0)
        guard let localMean = boxBlur(normalized, radius: sauvolaRadius, extent: extent),
              let squareKernel,
              let squared = squareKernel.apply(extent: extent, arguments: [normalized]),
              let localMeanSq = boxBlur(squared, radius: sauvolaRadius, extent: extent),
              let thresholdKernel,
              let thresholded = thresholdKernel.apply(
                  extent: extent,
                  arguments: [normalized, localMean, localMeanSq, CGFloat(0.34), CGFloat(0.5)]
              )
        else { return image }

        guard let cgOut = ciContext.createCGImage(thresholded, from: extent) else { return image }
        return UIImage(cgImage: cgOut, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - CI helpers

    private func boxBlur(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage? {
        let filter = CIFilter.boxBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
        return filter.outputImage?.cropped(to: extent)
    }

    private func cgImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let normalized = renderer.image { _ in image.draw(at: .zero) }
        return normalized.cgImage
    }
}
