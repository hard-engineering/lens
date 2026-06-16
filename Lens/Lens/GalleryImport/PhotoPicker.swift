import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct PhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPicked: ([NSItemProvider]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter = .images
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    /// Loads a picked photo as a downsampled UIImage. Uses
    /// `CGImageSourceCreateThumbnailAtIndex` so the full-resolution pixels
    /// are never materialized in memory — critical for HDR / panorama /
    /// high-MP iPhone photos that would otherwise decode to hundreds of MB.
    ///
    /// `maxPixelSize` is the longest-side cap. 3000 covers 300 DPI A4
    /// (~2500×3500) with margin and keeps RAM under ~36 MB per image.
    static func loadDownsampled(provider: NSItemProvider, maxPixelSize: Int = 3000) async -> UIImage? {
        let data: Data? = await withCheckedContinuation { continuation in
            let typeID = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeID) else {
                continuation.resume(returning: nil)
                return
            }
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cg)
        }.value
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([NSItemProvider]) -> Void
        let onCancel: () -> Void

        init(onPicked: @escaping ([NSItemProvider]) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if results.isEmpty {
                onCancel()
                return
            }
            // Hand back the lightweight providers immediately; decoding happens
            // on demand in GalleryImportFlow so we never hold all images at once.
            onPicked(results.map { $0.itemProvider })
        }
    }
}
