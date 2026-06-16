import SwiftUI
import UIKit

/// Drives the multi-image gallery import pipeline:
/// PHPicker -> (for each picked item provider) load+downsample -> detect quad ->
/// CornerEditor -> CIPerspectiveCorrection.
///
/// Memory discipline: we hold lightweight `NSItemProvider`s for the whole
/// selection, but only one `UIImage` is materialized at a time, decoded at
/// ≤3000 px so iPhone HDR/panorama photos never blow the per-process limit.
/// Each image is dropped after its warp is produced.
struct GalleryImportFlow: View {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    @State private var providers: [NSItemProvider] = []
    @State private var hasPicked: Bool = false
    @State private var currentIndex: Int = 0
    @State private var currentImage: UIImage?
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
                onPicked: { items in
                    providers = items
                    hasPicked = true
                    if items.isEmpty {
                        onCancel()
                    } else {
                        Task { await beginEditing(index: 0) }
                    }
                },
                onCancel: onCancel
            )
            .ignoresSafeArea()
        } else if currentIndex < providers.count {
            Group {
                if detecting || currentImage == nil {
                    detectingView(for: currentImage)
                } else if let image = currentImage {
                    CornerEditor(
                        image: image,
                        detectedQuad: detectedQuad,
                        quad: $currentQuad,
                        onConfirm: { commitCurrent(image: image) },
                        onCancel: skipCurrent
                    )
                }
            }
            .navigationTitle("Photo \(currentIndex + 1) of \(providers.count)")
        } else {
            ProgressView("Processing…").task { onComplete(warped) }
        }
    }

    /// Shown while we're loading/decoding the next image and while the
    /// detector is running. The centered spinner makes the in-progress state
    /// unmistakable; corners never appear until detection returns a real quad.
    private func detectingView(for image: UIImage?) -> some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .opacity(0.35)
                    .padding(16)
            }
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.3)
                Text("Detecting edges…")
                    .font(.headline)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func beginEditing(index: Int) async {
        await MainActor.run {
            detecting = true
            currentImage = nil
        }
        // Decode + downsample on a background task so we don't pin the main
        // thread, and so the prior image's memory is released before we
        // allocate the next one.
        guard let image = await PhotoPicker.loadDownsampled(provider: providers[index])?.normalizedUpright() else {
            await MainActor.run { advance() }
            return
        }
        let quad = await DocumentDetector.detectQuad(in: image)
        await MainActor.run {
            currentImage = image
            detectedQuad = quad
            currentQuad = quad
            detecting = false
        }
    }

    private func commitCurrent(image: UIImage) {
        if let rectified = PerspectiveWarp.apply(to: image, quad: currentQuad) {
            warped.append(rectified)
        } else {
            warped.append(image)
        }
        currentImage = nil // release before loading the next
        advance()
    }

    private func skipCurrent() {
        currentImage = nil
        advance()
    }

    private func advance() {
        let next = currentIndex + 1
        currentIndex = next
        if next < providers.count {
            Task { await beginEditing(index: next) }
        }
    }
}
