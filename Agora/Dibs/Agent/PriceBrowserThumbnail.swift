import SwiftUI
import WebKit

/// A tiny live picture of the in-app browser while the price worker looks something up
/// (the lookup started first, when two run at once). Hidden otherwise. Tap for a larger,
/// read-only view that closes itself 1.5 s after the lookup ends.
///
/// The web view stays in its offscreen window; this shows a snapshot of it every 0.5 s.
/// Place it top-right in the camera area:
/// `PriceBrowserThumbnail(worker: priceWorker).padding(12)` in a `.topTrailing` alignment.
struct PriceBrowserThumbnail: View {
    let worker: PriceWorker
    @State private var image: UIImage?
    @State private var sheetRequest: PriceWorker.Lookup?

    var body: some View {
        let lookup = PriceWorker.shownLookup(worker.active)
        ZStack {
            if let lookup {
                Button { sheetRequest = lookup } label: { thumbnail(lookup) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lookup.phase) \(lookup.name)")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lookup?.requestId)
        .task(id: lookup?.requestId) {
            guard let id = lookup?.requestId else { return }
            image = nil
            while !Task.isCancelled {
                if let view = worker.pageView(for: id), let shot = await PageSnapshot.take(view) { image = shot }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .sheet(item: $sheetRequest) { lookup in
            PriceBrowserSheet(worker: worker, lookup: lookup, image: image)
                .presentationDetents([.medium])
        }
    }

    private func thumbnail(_ lookup: PriceWorker.Lookup) -> some View {
        PagePicture(image: image)
            .frame(width: 56, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 1))
            .overlay(alignment: .bottom) {
                HStack(spacing: 2) {
                    Text(lookup.host)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    ActivityDots()
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, 4)
            }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

extension PriceWorker.Lookup: Identifiable {
    var id: String { requestId }
}

/// The larger read-only view: the page, the item and what the worker is doing.
private struct PriceBrowserSheet: View {
    let worker: PriceWorker
    let lookup: PriceWorker.Lookup
    let image: UIImage?
    @State private var liveImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let running = worker.active.contains { $0.requestId == lookup.requestId }
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(lookup.name)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .lineLimit(1)
                Text(PriceWorker.caption(requestId: lookup.requestId, active: worker.active, outcomes: worker.outcomes))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            PagePicture(image: liveImage ?? image)
                .aspectRatio(StoreBrowser.viewport.width / StoreBrowser.viewport.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 1))
                .allowsHitTesting(false)
        }
        .padding(16)
        .task {
            while !Task.isCancelled, worker.active.contains(where: { $0.requestId == lookup.requestId }) {
                if let view = worker.pageView(for: lookup.requestId), let shot = await PageSnapshot.take(view) { liveImage = shot }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .task(id: running) {
            guard !running else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { dismiss() }
        }
    }
}

/// The page snapshot, top-aligned and cropped to fill; a plain card until the first snapshot.
private struct PagePicture: View {
    let image: UIImage?

    var body: some View {
        Color.white
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
    }
}

/// Three dots that pulse in turn.
private struct ActivityDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 2.5, height: 2.5)
                        .opacity(i == step ? 1 : 0.35)
                }
            }
        }
    }
}

@MainActor
enum PageSnapshot {
    /// A 280 pt wide snapshot of the page (enough for the thumbnail and the sheet), or nil.
    static func take(_ view: WKWebView) async -> UIImage? {
        guard view.bounds.width > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 280
        return try? await view.takeSnapshot(configuration: config)
    }
}

#Preview {
    ZStack(alignment: .topTrailing) {
        Color(red: 0.11, green: 0.10, blue: 0.09).ignoresSafeArea()
        PriceBrowserThumbnail(worker: PriceWorker()).padding(12)
    }
}
