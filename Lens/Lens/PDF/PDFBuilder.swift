import Foundation
import UIKit
import PDFKit

/// Produces an A4, multi-page PDF with an invisible searchable text layer per spec §9.
///
/// Implementation note: emits the OCR layer via `kCGTextDrawingModeInvisible`
/// on a `UIGraphicsPDFRenderer` context rather than `PDFAnnotation(.freeText)`,
/// because PDFKit's own `PDFDocument.string` does not aggregate freeText
/// annotations — making the PDF appear non-searchable to most consumers.
enum PDFBuilder {

    /// A4 in PDF points.
    static let pageSize = CGSize(width: 595, height: 842)

    struct RenderablePage {
        let image: UIImage
        let words: [OCRWord]
    }

    /// Build the PDF and write it to a unique temporary file. Returns the file URL.
    static func write(pages: [RenderablePage], filename: String) throws -> URL {
        let sanitized = sanitize(filename: filename)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized).pdf")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let format = UIGraphicsPDFRendererFormat()
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        try renderer.writePDF(to: url) { context in
            for page in pages {
                context.beginPage()
                let cg = context.cgContext

                UIColor.white.setFill()
                cg.fill(bounds)

                let imageRect = aspectFit(page.image.size, in: bounds)
                page.image.draw(in: imageRect)

                drawInvisibleTextLayer(in: cg, words: page.words, imageRect: imageRect, pageHeight: bounds.height)
            }
        }
        return url
    }

    /// Draw each OCR word as real glyphs in invisible text-rendering mode so
    /// `PDFDocument.string`, Spotlight, Preview's search, and third-party PDF
    /// readers all index the text. Vision boxes are normalized with origin at
    /// lower-left of the source image; UIKit's text drawing uses a top-left
    /// origin, so we flip y as we map into `imageRect`.
    private static func drawInvisibleTextLayer(
        in cg: CGContext,
        words: [OCRWord],
        imageRect: CGRect,
        pageHeight: CGFloat
    ) {
        cg.saveGState()
        cg.setTextDrawingMode(.invisible)

        for word in words {
            let box = word.normalizedBoundingBox
            let rect = CGRect(
                x: imageRect.minX + box.minX * imageRect.width,
                y: imageRect.minY + (1 - box.minY - box.height) * imageRect.height,
                width: max(box.width * imageRect.width, 1),
                height: max(box.height * imageRect.height, 1)
            )
            let fontSize = max(rect.height * 0.85, 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.clear,
            ]
            (word.text as NSString).draw(in: rect, withAttributes: attrs)
        }

        cg.restoreGState()
    }

    private static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(
            x: bounds.midX - w / 2.0,
            y: bounds.midY - h / 2.0,
            width: w,
            height: h
        )
    }

    private static func sanitize(filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Scan" : trimmed
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return base.components(separatedBy: illegal).joined(separator: "-")
    }
}
