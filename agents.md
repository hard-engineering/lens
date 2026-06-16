# Agents Guide — Lens

Native iOS document scanner (iOS 16+, universal). Personal-use replacement for
Microsoft Lens (retiring 2026-03-09). Sideloaded via Xcode; no App Store, no
accounts, no telemetry, no persistence. Apple SDK only.

## Flow
Launch → Home ("Scan with Camera" / "Import from Photos") → capture or pick →
Review (filter, reorder, rename) → Save / Share. Spec §3 originally called
for the app to open straight into the scanner; this was overridden — the
home screen is now always the landing.

## Layout
- `Lens/Lens.xcodeproj` — hand-authored (objectVersion 56, opens in Xcode 15+)
- `Lens/Lens/` — SwiftUI app shell with UIKit bridges:
  - `Scanner/` `VNDocumentCameraViewController`
  - `GalleryImport/` PHPicker → `DocumentDetector` (scores
    `VNDetectDocumentSegmentationRequest` + `VNDetectRectanglesRequest`
    candidates by mean Sobel response along the proposed perimeter; picks
    max — segmentation tends to return the full canvas on flat scans and
    loses to a real page rectangle) → `CornerEditor` → `CIPerspectiveCorrection`
  - `Filters/BWDocumentFilter.swift` — `CIBoxBlur` + explicit `CIColorKernel`s
    (`shadowNormalize`, Sauvola k=0.34 R=0.5) in normalized 0..1 luminance.
    Do not revert to `CIDivideBlendMode` — it works in gamma sRGB and produced
    all-white output.
  - `OCR/OCRService.swift` — `VNRecognizeTextRequest`, accurate, en-US
  - `PDF/PDFBuilder.swift` — `UIGraphicsPDFRenderer` + `kCGTextDrawingModeInvisible`
    so OCR text appears in `PDFDocument.string`. `PDFAnnotation(.freeText)` does
    not — don't go back to it.
  - `Review/` — list, filename, share
- `Lens/LensTests/` (6 cases) + `Lens/LensUITests/` (2 cases)

## Status
Builds and tests green on Xcode 26.5 / iOS 26.5 Simulator (iPhone 17 Pro). §10
measured: B&W 156ms/2400px (budget 500ms), 5-page PDF 7ms (budget 1s), PDF
text round-trip OK, multi-page reorder/filter reflected. §11.3 review-screen
verified via screenshots in `test_outputs/pipeline/screenshots/`. Detector
now passes on `shadow_doc` (picked quad scores 3× the full-canvas baseline)
and beats baseline on `angled_doc` but lands on a sub-region of the page —
the perimeter-edge metric prefers the higher-contrast text block to the
page-on-background boundary. Real-camera input remains untested. Full punch
list in `IMPLEMENTATION_NOTES.md`.

## When editing
- Spec source of truth: `product.md` (v3.1). Keep dependency-free.
- Page cap 50, enforced as a Review warning. OCR runs on unfiltered input;
  filter is applied for display/PDF.
- Out of scope: cloud sync, library, extra filters/languages, Shortcuts, share
  extension (spec §14).

## Testing
- `xcodebuild test -scheme Lens -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
- Fixtures: `scripts/make_fixtures.py` → `test_inputs/`; copies bundled in
  `LensTests/Resources/`.
- UI tests bypass PHPicker (unreliable on iOS 26 simulator) via `LensApp`'s
  `-uiTestPreloadFixturePath <abs-path>` launch arg.
- Artifacts go to `TEST_RUN_OUTPUT_DIR` (hardcoded absolute path in the
  scheme — scheme env vars don't expand `$(SRCROOT)`).
