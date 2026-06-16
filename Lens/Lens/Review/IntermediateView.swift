import SwiftUI

/// Shown when no pages exist and the scanner has been dismissed without scans.
struct IntermediateView: View {
    let onScan: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.secondary)
            Text("Lens")
                .font(.largeTitle.weight(.semibold))
            Text("Scan documents or import from Photos.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Button(action: onScan) {
                    Label("Scan with Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onImport) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
