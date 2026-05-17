# Lens

A native iOS document scanner — personal-use replacement for Microsoft Lens. Scan
or import pages, run OCR, apply a B&W document filter, and share a searchable PDF.

No accounts, no library, no telemetry. Single linear flow: scan → review → share.

## Requirements

- macOS with Xcode 15+
- iOS 16+ device or simulator (universal: iPhone + iPad)

## Build & sideload

1. Open `Lens/Lens.xcodeproj`.
2. Select the **Lens** target and the **Signing & Capabilities** tab.
3. Set **Team** to your Apple ID (free or paid). Xcode will assign a unique bundle ID
   suffix if a clash occurs — the default is `dev.local.lens`.
4. Plug in your iPhone or iPad, choose it as the run destination, hit **Run**.

### Signing options

- **Free Apple ID**: the build is valid for 7 days; re-run from Xcode weekly to refresh.
- **Paid developer account ($99/yr)**: build is valid for 1 year.

### Permissions

The app requests camera and Photos access on first use. If denied, an alert offers
to open Settings.

## Project layout

```
Lens/
├── Lens.xcodeproj/
└── Lens/
    ├── LensApp.swift                 — SwiftUI App entry
    ├── RootCoordinator.swift         — top-level view & camera-permission flow
    ├── Info.plist
    ├── Assets.xcassets/              — app icon, accent color
    ├── Model/
    │   ├── ScannedPage.swift         — per-page state (image, filter, OCR)
    │   └── ScanState.swift           — top-level @MainActor store
    ├── Scanner/
    │   └── ScannerSheet.swift        — VNDocumentCameraViewController wrapper
    ├── GalleryImport/
    │   ├── PhotoPicker.swift         — PHPickerViewController wrapper
    │   ├── DocumentDetector.swift    — VNDetectDocumentSegmentationRequest
    │   ├── CornerEditor.swift        — UIKit corner editor + magnifier loupe
    │   ├── PerspectiveWarp.swift     — CIPerspectiveCorrection
    │   └── GalleryImportFlow.swift   — orchestration view
    ├── Filters/
    │   └── BWDocumentFilter.swift    — Sauvola + shadow normalization
    ├── OCR/
    │   └── OCRService.swift          — VNRecognizeTextRequest async wrapper
    ├── PDF/
    │   └── PDFBuilder.swift          — A4 PDFKit output with text annotations
    └── Review/
        ├── IntermediateView.swift
        ├── ReviewView.swift          — page list, filename, share
        └── PageRowView.swift
```

## Verification

The spec's §10 acceptance criteria and §11 visual verification protocol must be run
on a Mac with Xcode installed. See `IMPLEMENTATION_NOTES.md` for what was done and
what remains to be checked on-device.

Test fixture placeholders live in `/test_inputs/`; supply real images there before
running the visual checks. Outputs land in `/test_outputs/`.

## Out of scope

Cloud sync, library/persistence, additional filters, additional OCR languages,
annotations, Shortcuts integration. See spec §14.
