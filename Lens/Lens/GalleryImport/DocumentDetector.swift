import Foundation
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Quadrilateral expressed in normalized image coordinates (origin lower-left, 0..1)
/// — consistent with Vision's output for VNRectangleObservation.
struct DocumentQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint

    static let fullImage = DocumentQuad(
        topLeft: CGPoint(x: 0, y: 1),
        topRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 0),
        bottomRight: CGPoint(x: 1, y: 0)
    )
}

enum DocumentDetector {

    /// Detect a document quad. Gathers candidates from both
    /// `VNDetectDocumentSegmentationRequest` (good on real-camera input) and
    /// `VNDetectRectanglesRequest` (good on flat scans), then picks the one
    /// with the strongest edge response along its proposed perimeter.
    /// Score-based selection is detector-agnostic: whichever proposal sits on
    /// real image edges wins; the segmentation request's tendency to return
    /// the full canvas on flat input simply scores poorly and loses.
    ///
    /// Input is downsampled to ≤1024 px before Vision sees it: the seg model
    /// resizes internally anyway, the rectangle detector cost scales linearly
    /// with input pixels, and detectors return normalized 0..1 coords so the
    /// downstream perspective warp still operates on the full-res original.
    /// The two Vision requests run concurrently.
    static func detectQuad(in image: UIImage) async -> DocumentQuad {
        guard let originalCG = image.cgImage else { return .fullImage }
        let orientation = orientation(from: image)
        let t0 = Date()
        // Skip Vision entirely on enormous images if downsampling fails —
        // running rectangle detection on a 100+ MP image will OOM the app.
        // User can still drag the CornerEditor handles manually.
        let scaled: CGImage
        if let s = downsample(originalCG, maxSide: 1024) {
            scaled = s
        } else if max(originalCG.width, originalCG.height) <= 2048 {
            scaled = originalCG
        } else {
            #if DEBUG
            print("[detect] downsample failed on \(originalCG.width)x\(originalCG.height) — skipping Vision")
            #endif
            return .fullImage
        }
        #if DEBUG
        let scaleMs = Int(Date().timeIntervalSince(t0) * 1000)
        print("[detect] downsample \(originalCG.width)x\(originalCG.height) → \(scaled.width)x\(scaled.height) in \(scaleMs)ms")
        #endif

        async let rectQuads = detectViaRectangle(scaled, orientation: orientation)
        let segQuad: DocumentQuad?
        if #available(iOS 15.0, *) {
            async let s = detectViaSegmentation(scaled, orientation: orientation)
            segQuad = await s
        } else {
            segQuad = nil
        }

        var candidates: [DocumentQuad] = []
        if let q = segQuad { candidates.append(q) }
        candidates.append(contentsOf: await rectQuads)
        guard !candidates.isEmpty else { return .fullImage }

        guard let evidence = EdgeMagnitudeImage.make(from: scaled, orientation: orientation) else {
            return candidates[0]
        }
        let scored = candidates.map { ($0, evidence.score(quad: $0)) }
        #if DEBUG
        for (i, (q, s)) in scored.enumerated() {
            let cx = (q.topLeft.x + q.topRight.x + q.bottomLeft.x + q.bottomRight.x) / 4
            let cy = (q.topLeft.y + q.topRight.y + q.bottomLeft.y + q.bottomRight.y) / 4
            let edge = evidence.perimeterEdgeEnergy(quad: q)
            let contrast = evidence.interiorExteriorContrast(quad: q)
            print(String(format: "[detect] cand[%d] score=%.2f edge=%.2f contrast=%.3f center=(%.2f,%.2f)", i, s, edge, contrast, cx, cy))
        }
        #endif
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return .fullImage }
        #if DEBUG
        let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
        print("[detect] picked candidate \(scored.firstIndex(where: { $0.1 == best.1 }) ?? -1) of \(scored.count) in \(totalMs)ms total")
        #endif
        return best.0
    }

    // MARK: - Detector adapters

    @available(iOS 15.0, *)
    private static func detectViaSegmentation(_ cg: CGImage, orientation: CGImagePropertyOrientation) async -> DocumentQuad? {
        await withCheckedContinuation { continuation in
            let request = VNDetectDocumentSegmentationRequest { request, _ in
                if let obs = request.results?.first as? VNRectangleObservation {
                    continuation.resume(returning: DocumentQuad(
                        topLeft: obs.topLeft,
                        topRight: obs.topRight,
                        bottomLeft: obs.bottomLeft,
                        bottomRight: obs.bottomRight
                    ))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func detectViaRectangle(_ cg: CGImage, orientation: CGImagePropertyOrientation) async -> [DocumentQuad] {
        await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, _ in
                let observations = (request.results as? [VNRectangleObservation]) ?? []
                let quads = observations.map {
                    DocumentQuad(
                        topLeft: $0.topLeft,
                        topRight: $0.topRight,
                        bottomLeft: $0.bottomLeft,
                        bottomRight: $0.bottomRight
                    )
                }
                continuation.resume(returning: quads)
            }
            request.maximumObservations = 8
            request.minimumAspectRatio = 0.3
            request.maximumAspectRatio = 1.0
            request.minimumSize = 0.2
            request.quadratureTolerance = 35
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Downsample a CGImage so its longest side ≤ `maxSide`. Returns the
    /// original CGImage if it already fits.
    ///
    /// Hardcodes sRGB for the output context: source images from modern
    /// iPhones come in extended-range / Display P3 / HDR color spaces,
    /// which are incompatible with an 8-bit `CGContext` and cause
    /// `CGBitmapContextInfoCreate` to return nil. Color accuracy doesn't
    /// matter here — Vision uses this purely for shape detection.
    private static func downsample(_ cg: CGImage, maxSide: Int) -> CGImage? {
        let m = max(cg.width, cg.height)
        guard m > maxSide else { return cg }
        let scale = Double(maxSide) / Double(m)
        let w = max(1, Int(Double(cg.width) * scale))
        let h = max(1, Int(Double(cg.height) * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func orientation(from image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Scoring evidence (kept under the EdgeMagnitudeImage name for
// continuity with existing tests; now also carries a luminance buffer).

/// Downscaled image evidence used to score detector candidates. Holds both
/// the gradient-magnitude (edge) buffer and the luminance buffer so the
/// detector can ask "does this quad's perimeter sit on a real edge?" *and*
/// "is the interior visually separated from the exterior?".
struct EdgeMagnitudeImage {
    let edges: [UInt8]
    let luminance: [UInt8]
    let width: Int
    let height: Int

    private static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// Build both buffers. Downscales to a max side of 1024 so scoring stays
    /// well under the §10 budgets regardless of input size.
    static func make(from cg: CGImage, orientation: CGImagePropertyOrientation) -> EdgeMagnitudeImage? {
        let oriented = CIImage(cgImage: cg).oriented(orientation)
        let extent = oriented.extent
        let maxSide = max(extent.width, extent.height)
        let scale = min(1.0, 1024.0 / maxSide)
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = CGRect(
            x: 0,
            y: 0,
            width: floor(extent.width * scale),
            height: floor(extent.height * scale)
        )

        // Luminance = desaturated source.
        let lumFilter = CIFilter.colorControls()
        lumFilter.inputImage = scaled
        lumFilter.saturation = 0.0
        guard let lum = lumFilter.outputImage?.cropped(to: scaledExtent) else { return nil }

        // Edges from the luminance image (single-channel input keeps the
        // result well-defined regardless of input color space).
        let edgesFilter = CIFilter.edges()
        edgesFilter.inputImage = lum.clampedToExtent()
        edgesFilter.intensity = 5.0
        guard let edges = edgesFilter.outputImage?.cropped(to: scaledExtent) else { return nil }

        let w = Int(scaledExtent.width)
        let h = Int(scaledExtent.height)
        guard w > 0, h > 0 else { return nil }

        guard let lumBuf = render(image: lum, extent: scaledExtent, w: w, h: h),
              let edgeBuf = render(image: edges, extent: scaledExtent, w: w, h: h)
        else { return nil }
        return EdgeMagnitudeImage(edges: edgeBuf, luminance: lumBuf, width: w, height: h)
    }

    private static func render(image: CIImage, extent: CGRect, w: Int, h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let cg = Self.context.createCGImage(image, from: extent)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// Combined score = perimeter edge energy × |interior - exterior luminance|.
    /// Both factors are non-negative. A full-canvas candidate has an empty
    /// exterior, so its contrast factor is 0 and the score is 0. A small
    /// sub-rectangle fully inside the page has near-zero contrast (interior
    /// and exterior are both page-colored) and also scores low. The real
    /// document boundary has both real edges *and* a luminance step across
    /// it, so it wins.
    func score(quad: DocumentQuad) -> Double {
        let edge = perimeterEdgeEnergy(quad: quad)
        let contrast = interiorExteriorContrast(quad: quad)
        return edge * contrast
    }

    /// Total edge energy along the four edges of the quad: per edge, the
    /// mean gradient response (sampled at `samplesPerEdge` points, max within
    /// ±`perpRadius` perpendicular pixels) × edge length in pixels.
    func perimeterEdgeEnergy(quad: DocumentQuad, samplesPerEdge: Int = 64, perpRadius: Int = 2) -> Double {
        let segments: [(CGPoint, CGPoint)] = [
            (quad.topLeft, quad.topRight),
            (quad.topRight, quad.bottomRight),
            (quad.bottomRight, quad.bottomLeft),
            (quad.bottomLeft, quad.topLeft),
        ]
        let w = Double(width), h = Double(height)
        var total = 0.0
        for (a, b) in segments {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let normLen = hypot(dx, dy)
            guard normLen > 1e-6 else { continue }
            let px = -dy / normLen
            let py = dx / normLen
            var edgeSum = 0.0
            for i in 0..<samplesPerEdge {
                let t = Double(i) / Double(samplesPerEdge - 1)
                let x = a.x + CGFloat(t) * dx
                let y = a.y + CGFloat(t) * dy
                var best: Double = 0
                for r in -perpRadius...perpRadius {
                    let offset = CGFloat(r) / CGFloat(min(width, height))
                    let sx = x + px * offset
                    let sy = y + py * offset
                    best = max(best, sample(edges, sx, sy))
                }
                edgeSum += best
            }
            let meanResponse = edgeSum / Double(samplesPerEdge)
            let pxLen = sqrt(pow(Double(dx) * w, 2) + pow(Double(dy) * h, 2))
            total += meanResponse * pxLen
        }
        return total
    }

    /// |mean luminance inside quad − mean luminance outside quad|, in [0, 1].
    /// Sampled on an `n × n` grid. Returns 0 if either inside or outside has
    /// too few samples (e.g. full-canvas quad → empty outside).
    func interiorExteriorContrast(quad: DocumentQuad, gridSide: Int = 64) -> Double {
        var inSum = 0.0, outSum = 0.0
        var inCount = 0, outCount = 0
        let total = gridSide * gridSide
        for j in 0..<gridSide {
            for i in 0..<gridSide {
                let nx = (CGFloat(i) + 0.5) / CGFloat(gridSide)
                let ny = (CGFloat(j) + 0.5) / CGFloat(gridSide)
                let v = sample(luminance, nx, ny)
                if Self.isInside(CGPoint(x: nx, y: ny), quad: quad) {
                    inSum += v; inCount += 1
                } else {
                    outSum += v; outCount += 1
                }
            }
        }
        // Both partitions need enough samples for the means to be meaningful.
        let minCount = max(10, total / 50)
        guard inCount >= minCount, outCount >= minCount else { return 0 }
        return abs(inSum / Double(inCount) - outSum / Double(outCount))
    }

    /// Point-in-quad test using the consistent-cross-product method.
    /// Works for any convex quad regardless of vertex order.
    private static func isInside(_ p: CGPoint, quad: DocumentQuad) -> Bool {
        let pts = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var sign = 0
        for i in 0..<4 {
            let a = pts[i]
            let b = pts[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            let s: Int = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
            if s == 0 { continue }
            if sign == 0 { sign = s } else if sign != s { return false }
        }
        return true
    }

    /// Sample a byte buffer at normalized coords. Vision uses origin lower-left;
    /// the buffer is stored origin upper-left, so y is flipped.
    private func sample(_ buf: [UInt8], _ nx: CGFloat, _ ny: CGFloat) -> Double {
        let cx = nx.isFinite ? nx : 0
        let cy = ny.isFinite ? ny : 0
        let x = min(max(Int((cx * CGFloat(width)).rounded()), 0), width - 1)
        let yFlipped = (1.0 - cy) * CGFloat(height)
        let y = min(max(Int(yFlipped.rounded()), 0), height - 1)
        return Double(buf[y * width + x]) / 255.0
    }
}
