import Foundation
import UIKit
import Vision
import CoreImage

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

    /// Detect a document quad. Uses VNDetectDocumentSegmentationRequest on iOS 15+,
    /// falling back to the rectangle detector if nothing is found.
    static func detectQuad(in image: UIImage) async -> DocumentQuad {
        guard let cg = image.cgImage else { return .fullImage }

        if #available(iOS 15.0, *) {
            if let quad = await detectViaSegmentation(cg, orientation: orientation(from: image)) {
                return quad
            }
        }
        if let quad = await detectViaRectangle(cg, orientation: orientation(from: image)) {
            return quad
        }
        return .fullImage
    }

    @available(iOS 15.0, *)
    private static func detectViaSegmentation(_ cg: CGImage, orientation: CGImagePropertyOrientation) async -> DocumentQuad? {
        await withCheckedContinuation { continuation in
            let request = VNDetectDocumentSegmentationRequest { request, _ in
                let obs = request.results?.first as? VNRectangleObservation
                if let obs {
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

    private static func detectViaRectangle(_ cg: CGImage, orientation: CGImagePropertyOrientation) async -> DocumentQuad? {
        await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, _ in
                let candidates = (request.results as? [VNRectangleObservation]) ?? []
                if let best = candidates.max(by: { areaOf($0) < areaOf($1) }) {
                    continuation.resume(returning: DocumentQuad(
                        topLeft: best.topLeft,
                        topRight: best.topRight,
                        bottomLeft: best.bottomLeft,
                        bottomRight: best.bottomRight
                    ))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            request.maximumObservations = 4
            request.minimumAspectRatio = 0.3
            request.maximumAspectRatio = 1.0
            request.minimumSize = 0.2
            request.quadratureTolerance = 35
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func areaOf(_ r: VNRectangleObservation) -> CGFloat {
        let w = hypot(r.topRight.x - r.topLeft.x, r.topRight.y - r.topLeft.y)
        let h = hypot(r.bottomLeft.x - r.topLeft.x, r.bottomLeft.y - r.topLeft.y)
        return w * h
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
