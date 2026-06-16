import SwiftUI
import AVFoundation

/// Top-level view. Owns presentation of scanner/import flows and shows either
/// the launch intermediate screen or the Review screen depending on state.
struct RootView: View {
    @EnvironmentObject private var state: ScanState

    @State private var showScanner: Bool = false
    @State private var showImporter: Bool = false
    @State private var importerSession: UUID = UUID()
    @State private var permissionError: PermissionError?

    var body: some View {
        Group {
            if state.pages.isEmpty {
                IntermediateView(
                    onScan: { presentScanner() },
                    onImport: { showImporter = true }
                )
            } else {
                ReviewView(
                    onNewScan: { presentScanner() },
                    onAddFromPhotos: { showImporter = true }
                )
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            ScannerSheet(
                onScanned: { images in
                    showScanner = false
                    state.add(images: images)
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showImporter, onDismiss: { importerSession = UUID() }) {
            // .id() forces a fresh view identity per presentation so the
            // GalleryImportFlow's @State (providers, currentIndex, etc.) is
            // not preserved across sheet present/dismiss cycles.
            GalleryImportFlow(
                onComplete: { images in
                    showImporter = false
                    state.add(images: images)
                },
                onCancel: { showImporter = false }
            )
            .id(importerSession)
        }
        .alert(item: $permissionError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                primaryButton: .default(Text("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func presentScanner() {
        Task { await requestCameraThenPresent() }
    }

    private func requestCameraThenPresent() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showScanner = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                showScanner = true
            } else {
                permissionError = .cameraDenied
            }
        case .denied, .restricted:
            permissionError = .cameraDenied
        @unknown default:
            permissionError = .cameraDenied
        }
    }
}

struct PermissionError: Identifiable {
    let id: String
    let title: String
    let message: String

    static let cameraDenied = PermissionError(
        id: "camera",
        title: "Camera Access Required",
        message: "Lens needs the camera to scan documents. Enable access in Settings."
    )

    static let photosDenied = PermissionError(
        id: "photos",
        title: "Photos Access Required",
        message: "Lens needs Photos access to import images. Enable access in Settings."
    )
}
