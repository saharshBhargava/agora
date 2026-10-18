import SwiftUI

/// The shopper's invite screen, live from the shared `RunStore` (canvas Start.dc.html).
struct StartView: View {
    let ref: RunRef
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        StartScreen(
            run: store.run?.id == ref.runId ? store.run : nil,
            personId: ref.personId,
            joinLink: model.api.joinLink(runId: ref.runId),
            reconnecting: store.connection == .reconnecting,
            onStart: { model.path.append(.shopper(ref)) }
        )
        .task(id: ref) { model.enter(ref) }
    }
}

/// The invite screen's content, driven by plain values so previews need no server.
struct StartScreen: View {
    let run: Run?
    let personId: String
    let joinLink: URL
    var reconnecting = false
    var onStart: () -> Void = {}

    private var title: String { run?.title ?? "the run" }
    private var claimers: [Person] { run?.claimers ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Wordmark()

                VStack(alignment: .leading, spacing: 6) {
                    Text(RunText.openHeadline(store: run?.store ?? ""))
                        .font(.display(30))
                        .tracking(-0.5)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Send the link to your house chat. Anyone can join from home until you check out. Each person puts a \(Money.whole(RunText.holdCents)) hold on their own card.")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Color.bodyInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // One text item with the link in it: "Copy" then copies the link too (with a separate message,
                // Copy took only the message text), and Messages still shows it as a tappable link.
                ShareLink(
                    item: StartLogic.shareText(title: title, link: joinLink),
                    subject: Text(title),
                    preview: SharePreview(title)
                ) {
                    HStack(spacing: Metrics.space1) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
                        Text("Send link to the house chat")
                    }
                }
                .buttonStyle(.dibs(.blue, fontSize: 16))

                qrCard

                people

                if reconnecting {
                    Text(RunStore.reconnectingMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, Metrics.space1)
            .padding(.bottom, Metrics.space3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button("Clip phone to cart and start", action: onStart)
                .buttonStyle(.dibs(.ink, fontSize: 16))
                .padding(.horizontal, 20)
                .padding(.top, Metrics.space1)
                .padding(.bottom, Metrics.space1)
                .background(Color.paper)
        }
        .dibsScreen()
    }

    private var qrCard: some View {
        HStack(spacing: 14) {
            QRCodeView(text: joinLink.absoluteString)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Next to you? Scan to join")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text("Same link as the house chat, for anyone standing beside you.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .dibsCard(radius: 20, padding: 14)
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text("In the run")
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
            ForEach(claimers) { p in
                HStack(spacing: 10) {
                    Avatar(person: p, people: run?.people ?? [], me: personId, size: .sm)
                    Text(p.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: Metrics.space1)
                    Text(p.authorizedCents.map { "\(Money.whole($0)) held" } ?? "Joining…")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.authorizedCents == nil ? Color.muted : Color.shopperTeal)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
                .accessibilityElement(children: .combine)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Text(claimers.isEmpty ? "Waiting for your housemates…" : "Waiting for more…")
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .animation(.easeOut(duration: 0.2), value: claimers.map(\.id))
    }
}

#if DEBUG
private let previewLink = URL(string: "https://x.ngrok.app/join?run=\(PreviewData.runId)")!

#Preview("Start, Marcus in") {
    NavigationStack {
        StartScreen(run: PreviewData.oneInRun, personId: "jake", joinLink: previewLink)
    }
}

#Preview("Start, nobody yet") {
    NavigationStack {
        StartScreen(run: PreviewData.emptyRun, personId: "jake", joinLink: previewLink, reconnecting: true)
    }
}
#endif

/// What the invite share sheet sends.
enum StartLogic {
    static func shareText(title: String, link: URL) -> String { "Join \(title) on Dibs: \(link.absoluteString)" }
}
