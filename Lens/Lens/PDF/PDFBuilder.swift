import Foundation
import UIKit
import PDFKit

/// Produces an A4, multi-page PDF with an invisible searchable text layer per spec §9.
enum PDFBuilder {

    /// A4 in PDF points.
    static let pageSize = CGSize(width: 595, height: 842)

    struct RenderablePage {
        let image: UIImage
        let words: [OCRWord]
    }

    /// Build the PDF and write it to a unique temporary file. Returns the file URL.
    static func write(pages: [RenderablePage], filename: String) throws -> URL {
        let document = PDFDocument()
        for (index, page) in pages.enumerated() {
            let imageRectInPage = aspectFit(page.image.size, in: CGRect(origin: .zero, size: pageSize))
            let fitted = renderToA4(page.image, imageRect: imageRectInPage)
            guard let pdfPage = PDFPage(image: fitted) else { continue }
            // PDFPage adopts the image bounds. Force the media box to A4 so the page
            // is consistent and the OCR annotation coordinates compute correctly.
            pdfPage.setBounds(CGRect(origin: .zero, size: pageSize), for: .mediaBox)
            addSearchableTextLayer(to: pdfPage, words: page.words, imageRect: imageRectInPage)
            document.insert(pdfPage, at: index)
        }

        let sanitized = sanitize(filename: filename)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized).pdf")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        guard let data = document.dataRepresentation() else {
            throw NSError(domain: "PDFBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PDF."])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Draw the image fit-aspect into an A4 page on a white background.
    private static func renderToA4(_ image: UIImage, imageRect: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pageSize))
            image.draw(in: imageRect)
        }
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

    /// Add invisible PDF text annotations covering each OCR word's bounding box.
    /// Vision returns boxes in normalized coordinates with the origin at lower-left.
    /// PDFKit uses the same convention, so we scale boxes by the media bounds directly.
    private static func addSearchableTextLayer(to page: PDFPage, words: [OCRWord]) {
        let bounds = page.bounds(for: .mediaBox)
        for word in words {
            let box = word.normalizedBoundingBox
            let rect = CGRect(
                x: bounds.minX + box.minX * bounds.width,
                y: bounds.minY + box.minY * bounds.height,
                width: max(box.width * bounds.width, 1),
                height: max(box.height * bounds.height, 1)
            )
            let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = word.text
            annotation.color = .clear
            annotation.fontColor = .clear
            annotation.font = UIFont.systemFont(ofSize: 1)
            annotation.border = nil
            page.addAnnotation(annotation)
        }
    }

    private static func sanitize(filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Scan" : trimmed
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return base.components(separatedBy: illegal).joined(separator: "-")
    }
}
