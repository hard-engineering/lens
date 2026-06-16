# Lens — iOS Document Scanner

## Spec for Coding Agent · v3 (final)

**Purpose:** Personal-use replacement for Microsoft Lens (retiring March 9, 2026).
**Platform:** iOS 16+ universal (iPhone + iPad), fully native Swift.
**Distribution:** Personal sideload via Xcode. No App Store, no review, no telemetry, no branding work beyond a placeholder app icon.

-----

## 1. Mental Model

The app is a **scan-and-send utility**. No library, no persistence, no accounts. Single linear flow:

```
Launch → Scanner → Review → Share
              ↑                ↓
              └── New scan ────┘
```

Every scan ends by leaving the app (Share to Files, Photos, Mail, etc.). Nothing is stored long-term inside Lens itself.

## 2. Flow in Detail

1. **App launch** → opens directly into `VNDocumentCameraViewController` (no home screen).
1. **Scanner** (Apple VisionKit) — captures pages with live edge detection. Per-page corner correction is built into VisionKit’s own UI after each capture. Multi-page is built in. User can also tap “Photos” inside VisionKit, or via our gallery-import path (see §6).
1. **Post-scanner branch:**
- User taps “Save” inside VisionKit → all captured pages handed to app → run OCR and default B&W filter in background → present Review screen.
- User taps “Cancel” → app exits scanner → present a minimal “Start scan / Import from Photos” intermediate view.
1. **Review screen** — see §5.
1. **Share** — generate PDF, present `UIActivityViewController`. After dismissal, stay on Review screen so user can share again to another destination, or tap “New Scan” to reset.

## 3. Architecture

```
LensApp (SwiftUI App)
├── RootCoordinator           — presents scanner on launch, owns scan state
├── ScannerSheet              — UIViewControllerRepresentable wrapping VNDocumentCameraViewController
├── GalleryImportFlow
│   ├── PhotoPicker           — PHPickerViewController
│   ├── DocumentDetector      — VNDetectDocumentSegmentationRequest
│   ├── CornerEditor          — custom UIView with 4 draggable corner handles
│   └── PerspectiveWarp       — CIPerspectiveCorrection
├── Filters
│   ├── OriginalFilter        — passthrough
│   └── BWDocumentFilter      — Sauvola adaptive threshold + shadow normalization
├── OCRService                — VNRecognizeTextRequest, English only, .accurate level
├── PDFBuilder                — PDFKit, A4, multi-page, with searchable text layer
└── ReviewView (SwiftUI)
    ├── Page thumbnails, reorderable, deletable
    ├── Per-page filter toggle + "Apply to all" bulk action
    ├── Editable filename (default: "Scan YYYY-MM-DD HH-mm")
    ├── New Scan button
    └── Share button
```

**No third-party dependencies.** Everything is Apple SDK: VisionKit, Vision, CoreImage, PDFKit, PhotosUI, SwiftUI/UIKit.

## 4. Capture

### Live scanner (primary path)

```swift
import VisionKit

let scanner = VNDocumentCameraViewController()
scanner.delegate = self
present(scanner, animated: true)

func documentCameraViewController(
  _ controller: VNDocumentCameraViewController,
  didFinishWith scan: VNDocumentCameraScan
) {
  let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
  // Pages are already perspective-corrected by VisionKit
  controller.dismiss(animated: true) { [weak self] in
    self?.handleCapturedPages(pages)
  }
}
```

Page limit: 50 (enforced at UI level — don’t pass `pages.prefix(50)` until after capture, just warn if exceeded in Review).

### Known issue worth tracking

VisionKit on iOS 26 has UI regressions: cancel button missing on iPad, dimmed top bar on iPhone. Not fixable from our side. If it becomes intolerable, fallback option is to build custom capture UI using AVFoundation + `VNDetectDocumentSegmentationRequest` — significant work, deferred.

## 5. Review Screen

SwiftUI list of pages. Each row:

- Page thumbnail (filtered)
- Page number
- Filter picker (Original / B&W) — defaults to B&W
- Drag handle for reorder
- Delete button

Top of screen:

- Editable filename field (default: “Scan YYYY-MM-DD HH-mm”)
- “Apply to all: [Original / B&W]” segmented control (bulk action)

Bottom of screen:

- “New Scan” button (resets state, re-presents scanner)
- “Share” button (primary, generates PDF, presents share sheet)

Empty state (all pages deleted): show “Add pages” → re-presents scanner.

## 6. Gallery Import

Triggered from the “Cancel scanner → intermediate view” entry point, or as an “Add from Photos” action on the Review screen.

Flow per imported image:

1. PHPicker (single or multiple selection)
1. For each image, run `VNDetectDocumentSegmentationRequest` (iOS 15+) to get the document quad
1. Present **CornerEditor**: full-image view with 4 draggable corner handles overlaid on the detected quad. User can adjust.
1. On confirm, apply `CIPerspectiveCorrection` with the four corner points → output rectified image
1. Add to the current scan’s page array, alongside any pages from the live scanner

CornerEditor implementation notes:

- UIKit (`UIView` + `UIPanGestureRecognizer`), embedded in SwiftUI via `UIViewRepresentable`
- Magnifier-style loupe on the active corner (Apple-style) for precision dragging
- Snap-to-detected-quad button to reset
- Snap-to-image-bounds button as a fallback
- Touch targets: 44pt minimum

## 7. Filters

### Original

Passthrough. UIImage → UIImage with no processing.

### B&W Document

Two-stage:

**Stage 1 — Shadow normalization.** Divide each pixel’s luminance by an estimate of local background illumination. Implementation: large-radius box blur on the luminance channel (radius ≈ min(width, height) / 20), then `normalized = pixel / max(blurred, threshold)`, scaled to target white point ~235. Apply ratio across all channels to preserve color momentarily; then convert to grayscale.

**Stage 2 — Adaptive threshold (Sauvola).** For each pixel, compute local mean μ and standard deviation σ over a window (~15–25px). Threshold = μ · (1 + k · (σ/R − 1)), with k ≈ 0.34 and R ≈ 128. Pixels below threshold → black, above → white.

Implementation: Metal compute shader for speed, or vImage if Metal is overkill. Target: < 500ms per page at 2400px.

This is the headline filter. Visual quality bar: match or exceed Microsoft Lens’ “Document” mode on a side-by-side comparison with a shadow-cast paper document.

## 8. OCR

```swift
let request = VNRecognizeTextRequest { request, error in
  guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
  // Capture text + bounding boxes per page for PDF text layer
}
request.recognitionLanguages = ["en-US"]
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
```

Run on the **original captured page** (pre-filter) — VisionKit’s perspective-corrected output is best for OCR. B&W filter can degrade text recognition due to thresholding artifacts.

Per-page result: array of `(text, normalizedBoundingBox)`. Pass to PDFBuilder for searchable text layer.

OCR runs asynchronously between scanner-dismiss and Review-screen-presentation. If it hasn’t finished by share time, show a brief “Preparing PDF” indicator and wait. Acceptable latency: up to ~2s for a 5-page scan on iPhone 13 or newer.

## 9. PDF Generation

Use PDFKit:

```swift
let pdfDocument = PDFDocument()
for (i, page) in pages.enumerated() {
  let pdfPage = PDFPage(image: page.filteredImage)!
  // Add invisible text annotations for each OCR observation
  for word in page.ocrResults {
    let annotation = PDFAnnotation(bounds: word.bounds, forType: .freeText, withProperties: nil)
    annotation.contents = word.text
    annotation.color = .clear
    annotation.font = UIFont.systemFont(ofSize: 1)
    pdfPage.addAnnotation(annotation)
  }
  pdfDocument.insert(pdfPage, at: i)
}
let data = pdfDocument.dataRepresentation()
```

Page size: A4 (`595 × 842` points). Image fit: aspect-fill within page bounds, centered, white background.

Output as a temporary file in `FileManager.default.temporaryDirectory` so the share sheet can hand it off cleanly to other apps. Filename: user-supplied or default timestamp.

## 10. Acceptance Criteria (Agent-Verifiable)

Each criterion below is measurable, binary, or programmatically testable. The agent verifies all of these before declaring the build complete.

1. Cold-launch (app icon tap → camera viewfinder visible): < 1.5s on iPhone 13 simulator or newer (measure with `os_signpost` or wall-clock timestamps)
1. End-to-end latency from scanner dismiss to Review screen with OCR ready: < 3s for a 5-page scan
1. Filter application latency: < 500ms per page at 2400px on Release configuration
1. PDF generation (5 pages, with OCR text layer): < 1s
1. Share sheet presents `UIActivityViewController` containing the PDF; filename matches user input or default timestamp pattern
1. Generated PDF contains extractable text matching OCR output (parse with `PDFDocument`, confirm `string` property contains expected keywords from a known test input)
1. Multi-page reorder, delete, and per-page filter changes are reflected in output PDF (verify by page count, page-order image hashes, and pixel sampling for filter application)
1. Camera permission denial: app does not crash, shows error state with Settings deeplink button
1. Photos permission denial: gallery import path shows error state with Settings deeplink button
1. Universal app builds and launches on iPhone and iPad simulators without Auto Layout console warnings or runtime exceptions
1. No memory leaks during a 10-scan stress test (Instruments Allocations: heap growth bounded after final scan completes)
1. App icon and launch screen present (no Xcode placeholder asset warnings at build time)

## 11. Visual Verification Protocol (Agent Self-Inspection)

Two pieces of output cannot be verified by measurement alone: B&W filter quality and perspective-warp aesthetics. The agent captures simulator screenshots and inspects them using its own vision capabilities as part of its QA loop.

### 11.1 Test fixtures

The agent prepares two fixtures in `/test_inputs/`:

- `shadow_doc.jpg` — a photo of a printed document with directional lighting creating a visible shadow band across part of the page. If no real photo is available, the agent synthesizes one: take any public-domain document image, composite a black-to-transparent gradient over one half to simulate shadow.
- `angled_doc.jpg` — a document photographed at an oblique angle (~30° tilt), so the document quad is visibly non-rectangular.

### 11.2 Screenshot loop

For each visual checkpoint, the agent:

1. Loads the fixture into the simulator’s Photos library via `xcrun simctl addmedia booted /test_inputs/<fixture>.jpg`.
1. Drives the relevant flow in the running app (programmatically via UI test, or manually via simulator automation).
1. Saves the in-app output image to `/test_outputs/<step>.jpg`.
1. Captures a simulator screenshot via `xcrun simctl io booted screenshot /test_outputs/screenshots/<step>.png`.
1. **Inspects the screenshot using its vision tool** and judges against the pass criteria below.
1. If failed, iterates on the implementation. After 3 failed iterations on the same checkpoint, the agent stops, documents the issue in `IMPLEMENTATION_NOTES.md`, and flags it for the owner rather than silently shipping.

### 11.3 Visual pass criteria

**B&W filter** (input: `shadow_doc.jpg`, output: `bw_output.jpg`):

- Document background is uniform near-white across the entire page including the previously shadowed region; no visible shadow boundary
- Text is solid black, fully legible, no broken character strokes
- No salt-and-pepper noise in white regions
- No large black blotches in white regions

**Perspective warp** (input: `angled_doc.jpg`, output: `warp_output.jpg`):

- Output image is rectangular, document fills the frame edge-to-edge
- Document edges in the output are parallel to image edges
- Any text within the document runs horizontally and is undistorted
- No transparent or background-colored regions inside the rectified frame

**Review screen** (screenshot: `review_screen.png`):

- All scanned page thumbnails visible
- Per-page filter picker present on each row
- “Apply to all” segmented control visible at top
- Filename field is editable (cursor visible on tap)
- “New Scan” and “Share” buttons present at bottom

**Layout sanity** (screenshots: `iphone_portrait.png`, `iphone_landscape.png`, `ipad_split.png`):

- No clipped or truncated controls
- Tap targets visibly ≥ 44pt
- No text overlapping with other UI elements at default Dynamic Type size

## 12. Build Order

Each step is a working app, not a stub. Each ends with the relevant validation from §10 or §11.

1. **Scaffold** — Xcode project, SwiftUI App lifecycle, iOS 16 target, universal, dark-mode-aware
1. **Scanner integration** — Launch app → VisionKit scanner → display returned pages in temporary preview
1. **Review screen v1** — Multi-page list, reorder, delete, rename, passthrough rendering (no filters or OCR yet). **Run §11 review-screen screenshot check.**
1. **PDF export + share sheet** — Generate non-OCR PDF, share via `UIActivityViewController`. **Validate §10 criteria 4, 5.**
1. **OCR integration** — `VNRecognizeTextRequest` async, build searchable PDF text layer. **Validate §10 criterion 6.**
1. **B&W filter** — Sauvola + shadow normalization. **Validate §10 criterion 3 and §11 B&W visual check.**
1. **Per-page filter UI + “Apply to all” bulk action**. **Validate §10 criterion 7.**
1. **Gallery import path** — PHPicker → segmentation → corner editor → perspective warp. **Validate §11 perspective-warp visual check.**
1. **Edge cases** — permission denial flows, empty state, iPad split-view. **Validate §10 criteria 8, 9, 10 and §11 layout-sanity screenshots.**
1. **Polish** — app icon, launch screen, haptics on share, accessibility audit (VoiceOver labels, Dynamic Type). **Validate §10 criterion 12.**
1. **Final pass** — run all §10 criteria and §11 visual checks together; produce `IMPLEMENTATION_NOTES.md` summarizing any deviations or open issues.

## 13. Deliverables

1. Xcode project, builds on macOS with Xcode 15+
1. README with build + sideload instructions (free Apple ID 7-day signing, or paid developer cert for 1-year stable signing)
1. `/test_inputs/` with the two fixture images
1. `/test_outputs/` with the generated output images and screenshots from the visual verification loop
1. `IMPLEMENTATION_NOTES.md` summarizing spec deviations, open issues, and §11 self-assessment results
1. Placeholder app icon

## 14. Out of Scope (Phase 2 ideas)

Cloud sync, library/persistence, annotation, signature insertion, additional filters (Color, Grayscale, Whiteboard), additional OCR languages, watermarks, password-protected PDFs, custom paper sizes, vCard / table extraction, Shortcuts integration, Share Extension to receive images from other apps.

-----

**End of spec v3.1.**
