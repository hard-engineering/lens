import Foundation
import UIKit
import Combine

/// Top-level scan state owned by RootCoordinator and observed by the UI.
///
/// Heavy work runs on dedicated GCD queues, not `Task.detached`. Under load,
/// Swift's cooperative thread pool was silently dropping the 6th+ detached
/// task; GCD's scheduling is deterministic regardless of how many items
/// queue up.
@MainActor
final class ScanState: ObservableObject {
    @Published var pages: [ScannedPage] = []
    @Published var filename: String = ScanState.defaultFilename()
    @Published var isProcessing: Bool = false

    static let pageLimit = 50

    private let ocr = OCRService()
    private let bwFilter = BWDocumentFilter()
    /// Renders are serial — CIContext serializes work internally anyway, so
    /// pipelining 6 in parallel only adds memory pressure without speedup.
    private let renderQueue = DispatchQueue(label: "lens.render", qos: .userInitiated)
    /// OCR is concurrent (Vision internally parallelizes) but capped.
    private let ocrQueue = DispatchQueue(label: "lens.ocr", qos: .userInitiated, attributes: .concurrent)
    private var cancelledPageIDs: Set<UUID> = []

    static func defaultFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return "Scan \(f.string(from: Date()))"
    }

    func reset() {
        // Mark all in-flight renders / OCRs as cancelled. The work itself
        // can't be interrupted mid-CoreImage/Vision call but its result will
        // be ignored when it tries to write back.
        for page in pages { cancelledPageIDs.insert(page.id) }
        pages = []
        filename = ScanState.defaultFilename()
    }

    func add(images: [UIImage], defaultFilter: PageFilter = .bw) {
        for image in images {
            let page = ScannedPage(original: image, filter: defaultFilter)
            pages.append(page)
            #if DEBUG
            print("[state] add page \(page.id.uuidString.prefix(4)) filter=\(defaultFilter) size=\(Int(image.size.width))x\(Int(image.size.height)) total=\(pages.count)")
            #endif
            scheduleOCR(for: page)
            scheduleRender(for: page)
        }
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            cancelledPageIDs.insert(pages[index].id)
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
        let ocr = self.ocr
        let id = page.id
        let original = page.original
        ocrQueue.async { [weak self, weak page] in
            let words = (try? ocr.recognizeTextSync(in: original)) ?? []
            DispatchQueue.main.async {
                guard let self, let page, !self.cancelledPageIDs.contains(id) else { return }
                page.ocrWords = words
                page.ocrFinished = true
            }
        }
    }

    private func scheduleRender(for page: ScannedPage) {
        let filter = page.filter
        let original = page.original
        let bw = bwFilter
        let id = page.id
        renderQueue.async { [weak self, weak page] in
            #if DEBUG
            print("[state] render \(id.uuidString.prefix(4)) \(filter) start")
            #endif
            let rendered: UIImage
            switch filter {
            case .original:
                rendered = original
            case .bw:
                let t0 = Date()
                rendered = bw.apply(to: original)
                #if DEBUG
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let sameRef = rendered === original
                print("[state] render \(id.uuidString.prefix(4)) bw done in \(ms)ms fallback-to-original=\(sameRef)")
                #endif
            }
            DispatchQueue.main.async {
                guard let self,
                      let page,
                      page.filter == filter,
                      !self.cancelledPageIDs.contains(id)
                else {
                    #if DEBUG
                    print("[state] render \(id.uuidString.prefix(4)) dropped — page gone, filter changed, or cancelled")
                    #endif
                    return
                }
                page.cachedRendered = rendered
            }
        }
    }
}
