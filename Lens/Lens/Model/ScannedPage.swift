import Foundation
import UIKit

enum PageFilter: String, CaseIterable, Identifiable, Codable {
    case original
    case bw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .bw: return "B&W"
        }
    }
}

struct OCRWord: Hashable {
    let text: String
    /// Normalized rect in Vision coordinates (origin lower-left, 0..1).
    let normalizedBoundingBox: CGRect
}

final class ScannedPage: Identifiable, ObservableObject {
    let id = UUID()

    /// The perspective-corrected page image as captured (pre-filter). OCR runs on this.
    let original: UIImage

    @Published var filter: PageFilter
    @Published var ocrWords: [OCRWord] = []
    @Published var ocrFinished: Bool = false

    /// Cached filtered output for the current `filter`. Reset when filter changes.
    @Published var cachedRendered: UIImage?

    init(original: UIImage, filter: PageFilter = .bw) {
        self.original = original
        self.filter = filter
    }
}
