import SwiftUI
import UIKit

/// Drives the multi-image gallery import pipeline:
/// PHPicker -> (for each image) detect quad -> CornerEditor -> CIPerspectiveCorrection
struct GalleryImportFlow: View {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    @State private var pickedImages: [UIImage] = []
    @State private var hasPicked: Bool = false
    @State private var currentIndex: Int = 0
    @State private var currentQuad: DocumentQuad = .fullImage
    @State private var detectedQuad: DocumentQuad = .fullImage
    @State private var detecting: Bool = false
    @State private var warped: [UIImage] = []

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasPicked {
            PhotoPicker(
                selectionLimit: 0,
                onPicked: { images in
                    pickedImages = images
                    hasPicked = true
                    if images.isEmpty {
                        onCancel()
                    } else {
                        Task { await beginEditing(index: 0) }
                    }
                },
                onCancel: onCancel
            )
            .ignoresSafeArea()
        } else if currentIndex < pickedImages.count {
            let image = pickedImages[currentIndex]
            VStack(spacing: 0) {
                if detecting {
                    ProgressView("Detecting edges…")
                        .padding(.top, 16)
                }
                CornerEditor(
                    image: image.normalizedUpright(),
                    detectedQuad: detectedQuad,
                    quad: $currentQuad,
                    onConfirm: { commitCurrent(image: image) },
                    onCancel: skipCurrent
                )
            }
            .navigationTitle("Photo \(currentIndex + 1) of \(pickedImages.count)")
        } else {
            ProgressView("Processing…").task { onComplete(warped) }
        }
    }

    private func beginEditing(index: Int) async {
        detecting = true
        let image = pickedImages[index].normalizedUpright()
        let quad = await DocumentDetector.detectQuad(in: image)
        await MainActor.run {
            detectedQuad = quad
            currentQuad = quad
            detecting = false
        }
    }

    private func commitCurrent(image: UIImage) {
        let upright = image.normalizedUpright()
        if let rectified = PerspectiveWarp.apply(to: upright, quad: currentQuad) {
            warped.append(rectified)
        } else {
            warped.append(upright)
        }
        advance()
    }

    private func skipCurrent() {
        advance()
    }

    private func advance() {
        let next = currentIndex + 1
        currentIndex = next
        if next < pickedImages.count {
            Task { await beginEditing(index: next) }
        }
    }
}
