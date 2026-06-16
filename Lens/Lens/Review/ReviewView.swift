import SwiftUI
import UIKit
import Photos

struct ReviewView: View {
    @EnvironmentObject private var state: ScanState
    let onNewScan: () -> Void
    let onAddFromPhotos: () -> Void

    @State private var shareURL: URL?
    @State private var exportURL: URL?
    @State private var preparing: Bool = false
    @State private var showPreparingOverlay: Bool = false
    @State private var bulkFilter: PageFilter = .bw
    @State private var pageLimitWarning: Bool = false
    @State private var showAddDialog: Bool = false
    @State private var showDiscardConfirm: Bool = false
    @State private var saveResult: SaveResult?
    @State private var newScanOfferText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                newScanBanner
                topControls
                Divider()
                pageList
                Divider()
                bottomBar
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { newValue in if newValue == nil { shareURL = nil } }
        )) { item in
            ShareSheet(activityItems: [item.url]) { completed in
                shareURL = nil
                if completed { offerNewScan("Shared") }
            }
        }
        .sheet(item: Binding(
            get: { exportURL.map { ShareItem(url: $0) } },
            set: { newValue in if newValue == nil { exportURL = nil } }
        )) { item in
            DocumentExporter(url: item.url) { saved in
                exportURL = nil
                if saved { offerNewScan("Saved to Files") }
            }
        }
        .alert(item: $saveResult) { result in
            Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text("OK")))
        }
        .overlay {
            if showPreparingOverlay {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("Preparing PDF…")
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onChange(of: state.pages.count) { newValue in
            if newValue > ScanState.pageLimit {
                pageLimitWarning = true
            }
        }
        .alert("Too many pages",
               isPresented: $pageLimitWarning,
               actions: { Button("OK", role: .cancel) {} },
               message: { Text("Lens supports up to \(ScanState.pageLimit) pages per scan. Consider splitting into multiple scans.") })
        .alert(
            "Discard \(state.pages.count) \(state.pages.count == 1 ? "page" : "pages")?",
            isPresented: $showDiscardConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { state.reset() }
        } message: {
            Text("This clears the current scan. The action cannot be undone.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var newScanBanner: some View {
        if let text = newScanOfferText {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(text)
                    .font(.callout)
                Spacer()
                Button("Stay") {
                    withAnimation { newScanOfferText = nil }
                }
                .buttonStyle(.borderless)
                Button("New Scan") {
                    withAnimation { newScanOfferText = nil }
                    state.reset()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var topControls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("Filename", text: $state.filename)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .submitLabel(.done)
            }
            HStack {
                Text("Apply to all")
                    .foregroundStyle(.secondary)
                Picker("Apply to all", selection: $bulkFilter) {
                    ForEach(PageFilter.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: bulkFilter) { state.applyToAll($0) }
            }
        }
        .padding(16)
    }

    private var pageList: some View {
        List {
            ForEach(Array(state.pages.enumerated()), id: \.element.id) { index, page in
                PageRowView(
                    page: page,
                    index: index,
                    onFilterChange: { state.setFilter($0, for: page) },
                    onDelete: { state.remove(at: IndexSet(integer: index)) }
                )
            }
            .onMove { state.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    showDiscardConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Discard Scan")
                .disabled(state.pages.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { showAddDialog = true } label: {
                Label("Add", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Add Pages")
            .confirmationDialog("Add pages", isPresented: $showAddDialog, titleVisibility: .hidden) {
                Button("Scan with Camera") { onNewScan() }
                Button("Import from Photos") { onAddFromPhotos() }
                Button("Cancel", role: .cancel) {}
            }

            Menu {
                Button {
                    savePDFToFiles()
                } label: {
                    Label("Save PDF to Files", systemImage: "doc")
                }
                Button {
                    savePagesToPhotos()
                } label: {
                    Label("Save Pages to Photos", systemImage: "photo.on.rectangle")
                }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .disabled(state.pages.isEmpty)
            .accessibilityLabel("Save")

            Button(action: share) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.pages.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func share() {
        buildPDF { url in shareURL = url }
    }

    private func savePDFToFiles() {
        buildPDF { url in exportURL = url }
    }

    private func savePagesToPhotos() {
        let images = state.pages.map { $0.cachedRendered ?? $0.original }
        guard !images.isEmpty else { return }
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveResult = .photosDenied
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for image in images {
                        PHAssetCreationRequest.creationRequestForAsset(from: image)
                    }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                offerNewScan("Saved \(images.count) \(images.count == 1 ? "page" : "pages") to Photos")
            } catch {
                saveResult = .photosFailed(error: error.localizedDescription)
            }
        }
    }

    /// Show the post-save banner inviting the user to start a new scan.
    /// Called after any successful save/share path.
    private func offerNewScan(_ message: String) {
        withAnimation { newScanOfferText = message }
    }

    /// Build the searchable PDF off the main thread and hand the URL to `then`.
    /// Used by Share, Save to Files, and any other consumer that wants a URL.
    /// The Preparing overlay only appears if work takes >250ms — sub-frame
    /// builds (the common case once OCR is done) finish before any visual
    /// indicator would have helped, so we skip the flicker.
    ///
    /// All `@State` mutations stay on @MainActor; only the PDFKit write
    /// itself runs on a detached task. On device, SwiftUI is strict about
    /// state updates happening on the main actor — without this the share
    /// and save buttons can silently fail to present their sheets.
    private func buildPDF(then: @escaping @MainActor (URL) -> Void) {
        #if DEBUG
        print("[pdf] buildPDF tapped: pages=\(state.pages.count) preparing=\(preparing)")
        #endif
        guard !preparing else { return }
        preparing = true
        let overlayTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if preparing { showPreparingOverlay = true }
        }
        Task { @MainActor in
            await state.awaitOCR(timeout: 10)
            let renderable: [PDFBuilder.RenderablePage] = state.pages.map { page in
                PDFBuilder.RenderablePage(
                    image: page.cachedRendered ?? page.original,
                    words: page.ocrWords
                )
            }
            let filename = state.filename
            // Hop to a GCD queue for the PDF write instead of Task.detached:
            // the cooperative pool has been observed to drop work under load
            // when many detached tasks pile up, which left buildPDF hung
            // waiting on a result that never came.
            let url: URL? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: try? PDFBuilder.write(
                        pages: renderable, filename: filename
                    ))
                }
            }
            overlayTask.cancel()
            preparing = false
            showPreparingOverlay = false
            #if DEBUG
            print("[pdf] build returned url=\(url?.lastPathComponent ?? "nil") pages=\(renderable.count)")
            #endif
            if let url {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                then(url)
            } else {
                saveResult = SaveResult(
                    id: "pdf-failed",
                    title: "Could not create PDF",
                    message: "PDF generation failed. Try removing a page or restarting the app."
                )
            }
        }
    }
}

struct SaveResult: Identifiable {
    let id: String
    let title: String
    let message: String

    static func photosSaved(count: Int) -> SaveResult {
        SaveResult(
            id: "photos-saved",
            title: "Saved to Photos",
            message: "\(count) \(count == 1 ? "page" : "pages") added to your Photos library."
        )
    }

    static let photosDenied = SaveResult(
        id: "photos-denied",
        title: "Photos Access Denied",
        message: "Lens needs add-only access to save pages. Enable it in Settings → Privacy → Photos."
    )

    static func photosFailed(error: String) -> SaveResult {
        SaveResult(id: "photos-failed", title: "Save Failed", message: error)
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    /// Fired when the share sheet closes. `completed=true` means the user
    /// picked an activity that finished (Save to Files, Mail, etc.).
    /// `completed=false` is a user cancel.
    let onComplete: (_ completed: Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Wraps `UIDocumentPickerViewController` in export mode so the user picks
/// the destination (iCloud Drive, On My iPhone, etc.) for the generated PDF.
/// `onComplete(saved:)` reports whether the user actually picked a location.
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (_ saved: Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (_ saved: Bool) -> Void
        init(onComplete: @escaping (_ saved: Bool) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete(true)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(false)
        }
    }
}
