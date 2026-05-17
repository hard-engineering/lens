import Foundation
import UIKit
import Combine

/// Top-level scan state owned by RootCoordinator and observed by the UI.
@MainActor
final class ScanState: ObservableObject {
    @Published var pages: [ScannedPage] = []
    @Published var filename: String = ScanState.defaultFilename()
    @Published var isProcessing: Bool = false

    static let pageLimit = 50

    private let ocr = OCRService()
    private let bwFilter = BWDocumentFilter()
    private var renderTasks: [UUID: Task<Void, Never>] = [:]

    static func defaultFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return "Scan \(f.string(from: Date()))"
    }

    func reset() {
        cancelAllRendering()
        pages = []
        filename = ScanState.defaultFilename()
    }

    func add(images: [UIImage], defaultFilter: PageFilter = .bw) {
        for image in images {
            let page = ScannedPage(original: image, filter: defaultFilter)
            pages.append(page)
            scheduleOCR(for: page)
            scheduleRender(for: page)
        }
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            renderTasks[pages[index].id]?.cancel()
            renderTasks[pages[index].id] = nil
        }
        pages.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    func setFilter(_ filter: PageFilter, for page: ScannedPage) {
        guard page.filter != filter else { return }
        page.filter = filter
        page.cachedRendered = nil
        scheduleRender(for: page)
    }

    func applyToAll(_ filter: PageFilter) {
        for page in pages where page.filter != filter {
            page.filter = filter
            page.cachedRendered = nil
            scheduleRender(for: page)
        }
    }

    /// Returns true if every page has finished OCR.
    var allOCRFinished: Bool {
        pages.allSatisfy { $0.ocrFinished }
    }

    /// Waits for any in-flight OCR to complete. Returns when all pages have results
    /// or after the timeout, whichever comes first.
    func awaitOCR(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !allOCRFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func scheduleOCR(for page: ScannedPage) {
        Task.detached(priority: .userInitiated) { [ocr, weak page] in
            guard let page else { return }
            let words = (try? await ocr.recognizeText(in: page.original)) ?? []
            await MainActor.run {
                page.ocrWords = words
                page.ocrFinished = true
            }
        }
    }

    private func scheduleRender(for page: ScannedPage) {
        renderTasks[page.id]?.cancel()
        let filter = page.filter
        let original = page.original
        let bw = bwFilter
        let task = Task.detached(priority: .userInitiated) { [weak page] in
            let rendered: UIImage
            switch filter {
            case .original:
                rendered = original
            case .bw:
                rendered = bw.apply(to: original)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let page, page.filter == filter else { return }
                page.cachedRendered = rendered
            }
        }
        renderTasks[page.id] = task
    }

    private func cancelAllRendering() {
        for task in renderTasks.values { task.cancel() }
        renderTasks.removeAll()
    }
}
