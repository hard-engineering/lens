import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Black-and-white document filter implementing spec §7:
///   Stage 1 — Shadow normalization: divide luminance by a large-radius box-blur
///   estimate of local background illumination.
///   Stage 2 — Sauvola adaptive threshold: t = mean * (1 + k * (sigma/R - 1))
///
/// Both stages run as CoreImage filter chains. The Sauvola step uses a CIColorKernel
/// that samples three pre-computed images at the same coordinate: the normalized
/// luminance, the local mean, and the local mean-of-squares (used to derive stddev).
final class BWDocumentFilter {

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private lazy var thresholdKernel: CIColorKernel? = {
        let src = """
        kernel vec4 sauvola(__sample lum, __sample mean, __sample meanSq, float k, float R) {
            float m = mean.r;
            float s2 = max(meanSq.r - m * m, 0.0);
            float s = sqrt(s2);
            float t = m * (1.0 + k * (s / R - 1.0));
            float v = lum.r < t ? 0.0 : 1.0;
            return vec4(v, v, v, 1.0);
        }
        """
        return CIColorKernel(source: src)
    }()

    /// Apply the full pipeline. Returns the original image if any step fails.
    func apply(to image: UIImage) -> UIImage {
        guard let cgInput = cgImage(from: image) else { return image }
        let ci = CIImage(cgImage: cgInput)
        let extent = ci.extent

        // Stage 0: luminance (grayscale)
        let lumFilter = CIFilter.colorControls()
        lumFilter.inputImage = ci
        lumFilter.saturation = 0.0
        lumFilter.brightness = 0.0
        lumFilter.contrast = 1.0
        guard let lum = lumFilter.outputImage else { return image }

        // Stage 1: shadow normalization — large-radius box blur as background estimate.
        let shortSide = min(extent.width, extent.height)
        let shadowRadius = max(8.0, shortSide / 20.0)
        guard let background = boxBlur(lum, radius: shadowRadius, extent: extent) else { return image }
        guard let normalized = divide(lum, by: background, extent: extent) else { return image }

        // Stage 2: Sauvola — local mean and local mean-of-squares over a ~21px window.
        let sauvolaRadius = max(7.0, shortSide / 140.0)
        guard let localMean = boxBlur(normalized, radius: sauvolaRadius, extent: extent) else { return image }
        guard let squared = multiply(normalized, by: normalized, extent: extent) else { return image }
        guard let localMeanSq = boxBlur(squared, radius: sauvolaRadius, extent: extent) else { return image }

        guard let kernel = thresholdKernel else { return image }
        let k: CGFloat = 0.34
        let R: CGFloat = 0.5 // working in 0..1 luminance space, so R is half the dynamic range
        guard let thresholded = kernel.apply(
            extent: extent,
            arguments: [normalized, localMean, localMeanSq, k, R]
        ) else { return image }

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

    private func divide(_ a: CIImage, by b: CIImage, extent: CGRect) -> CIImage? {
        // CIDivideBlendMode: result = base / blend (per spec docs). We treat `a` as foreground,
        // `b` as background. Output is then scaled towards white.
        let blend = CIFilter.divideBlendMode()
        blend.inputImage = a
        blend.backgroundImage = b
        guard let out = blend.outputImage?.cropped(to: extent) else { return nil }
        // Slight gain so the page background sits near ~0.92 rather than blowing out.
        let gain = CIFilter.colorControls()
        gain.inputImage = out
        gain.brightness = 0.0
        gain.contrast = 1.0
        gain.saturation = 0.0
        return gain.outputImage?.cropped(to: extent)
    }

    private func multiply(_ a: CIImage, by b: CIImage, extent: CGRect) -> CIImage? {
        let blend = CIFilter.multiplyCompositing()
        blend.inputImage = a
        blend.backgroundImage = b
        return blend.outputImage?.cropped(to: extent)
    }

    private func cgImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let normalized = renderer.image { _ in image.draw(at: .zero) }
        return normalized.cgImage
    }
}
