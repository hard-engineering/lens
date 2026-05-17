import SwiftUI

struct PageRowView: View {
    @ObservedObject var page: ScannedPage
    let index: Int
    let onFilterChange: (PageFilter) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = page.cachedRendered ?? page.original.cgImage.map({ UIImage(cgImage: $0) }) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 96)
                        .clipped()
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                } else {
                    ProgressView()
                        .frame(width: 72, height: 96)
                }
            }
            .accessibilityLabel("Page \(index + 1) thumbnail")

            VStack(alignment: .leading, spacing: 8) {
                Text("Page \(index + 1)")
                    .font(.headline)
                Picker("Filter", selection: Binding(
                    get: { page.filter },
                    set: { onFilterChange($0) }
                )) {
                    ForEach(PageFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete page \(index + 1)")
        }
        .padding(.vertical, 4)
    }
}
