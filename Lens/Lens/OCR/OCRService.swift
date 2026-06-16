import Foundation
import UIKit
import Vision

final class OCRService {

    enum OCRError: Error {
        case missingCGImage
        case visionFailed(Error)
    }

    /// Recognize text in the image. Returns words with normalized bounding boxes
    /// in Vision's coordinate space (origin lower-left, 0..1).
    func recognizeText(in image: UIImage) async throws -> [OCRWord] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.recognizeTextSync(in: image))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous OCR — used from GCD-based schedulers in `ScanState`. The
    /// underlying `VNImageRequestHandler.perform` already blocks until Vision
    /// is done; the previous async wrapper only existed to bridge into Swift
    /// concurrency.
    func recognizeTextSync(in image: UIImage) throws -> [OCRWord] {
        guard let cg = image.cgImage ?? renderCG(image) else {
            throw OCRError.missingCGImage
        }
        var words: [OCRWord] = []
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string
                if text.isEmpty { continue }
                words.append(OCRWord(text: text, normalizedBoundingBox: obs.boundingBox))
            }
        }
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.visionFailed(error)
        }
        return words
    }

    private func renderCG(_ image: UIImage) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(at: .zero) }.cgImage
    }
}

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
