import SwiftUI
import UIKit

struct ReviewView: View {
    @EnvironmentObject private var state: ScanState
    let onNewScan: () -> Void
    let onAddFromPhotos: () -> Void

    @State private var shareURL: URL?
    @State private var preparing: Bool = false
    @State private var bulkFilter: PageFilter = .bw
    @State private var pageLimitWarning: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
            ShareSheet(activityItems: [item.url])
        }
        .overlay {
            if preparing {
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
    }

    // MARK: - Sections

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
            .onDelete { state.remove(at: $0) }
            .onMove { state.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .toolbar { EditButton() }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(action: onNewScan) {
                Label("New Scan", systemImage: "camera")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)

            Button(action: onAddFromPhotos) {
                Label("Photos", systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)

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
        guard !preparing else { return }
        preparing = true
        Task {
            await state.awaitOCR(timeout: 10)
            let renderable: [PDFBuilder.RenderablePage] = state.pages.map { page in
                PDFBuilder.RenderablePage(
                    image: page.cachedRendered ?? page.original,
                    words: page.ocrWords
                )
            }
            let filename = state.filename
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                try? PDFBuilder.write(pages: renderable, filename: filename)
            }.value
            preparing = false
            if let url = url {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                shareURL = url
            }
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
