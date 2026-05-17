import SwiftUI
import PhotosUI
import UIKit

struct PhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onPicked: ([UIImage]) -> Void
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

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onPicked: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if results.isEmpty {
                onCancel()
                return
            }

            let group = DispatchGroup()
            var collected = Array<UIImage?>(repeating: nil, count: results.count)
            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    if let image = object as? UIImage {
                        collected[index] = image
                    }
                }
            }
            group.notify(queue: .main) { [onPicked] in
                onPicked(collected.compactMap { $0 })
            }
        }
    }
}
