import SwiftUI
import UIKit

/// Join a run: name, hold amount, then a Visa authorization on the test card (canvas Main.dc.html,
/// docs/screenshots/v2-1-join.jpg). A declined authorization shows the server's message.
struct JoinView: View {
    let runId: String
    var decline = false
    /// Previews pass a run so nothing is fetched.
    var previewRun: Run?

    static let nameKey = "dibs.name"

    @Environment(AppModel.self) private var model
    @State private var run: Run?
    @State private var name = UserDefaults.standard.string(forKey: JoinView.nameKey) ?? ""
    @State private var capCents = RunText.holdCents
    @State private var busy = false
    @State private var error: String?
    @State private var joined: JoinResult?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shopper: Person? { run?.shopper }
    private var meId: String { joined?.personId ?? "__joiner" }

    /// Shopper, the others already in, then the joiner (dashed until the hold is placed).
    private var people: [Person] {
        let joiner = Person(id: meId, name: trimmedName, initial: RunText.initial(of: trimmedName), isShopper: false)
        let others = (run?.claimers ?? []).filter { $0.id != meId }
        return (shopper.map { [$0] } ?? []) + others + [joiner]
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Wordmark()
                    Spacer()
                    if let shopper {
                        Text("Invited by \(shopper.name)")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.muted)
                    }
                }

                runCard
                nameField
                hold

                if let joined {
                    VStack(alignment: .leading, spacing: Metrics.space1) {
                        HeldBadge(cents: joined.auth.authorizedCents, approvalCode: joined.auth.approvalCode)
                        Text("You are in. Watch the cart and claim what is yours.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dibsCard()
                    .id("joined")
                }
                if let error {
                    ErrorText(message: error).id("error")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, Metrics.space1)
            .padding(.bottom, Metrics.space3)
        }
        .onChange(of: joined) { _, new in
            if new != nil { withAnimation { scroller.scrollTo("joined", anchor: .bottom) } }
        }
        .onChange(of: error) { _, new in
            if new != nil { withAnimation { scroller.scrollTo("error", anchor: .bottom) } }
        }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .dibsScreen()
        .task(id: runId) { await load() }
    }

    // MARK: sections

    private var runCard: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE RUN")
                    .font(.system(size: 13))
                    .tracking(1)
                    .foregroundStyle(Color.muted)
                Text(run?.title ?? "Join the run")
                    .font(.display(30))
                    .tracking(-0.5)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                AvatarStack(list: people, people: people, me: meId, dashedId: joined == nil ? meId : nil)
                if let run {
                    Text(RunText.whoLine(run: run, excluding: meId))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let run, !RunText.cartTiles(run).isEmpty {
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text("In the cart so far")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                    HStack(spacing: Metrics.space1) {
                        ForEach(RunText.cartTiles(run)) { chip in
                            CartTile(chip: chip)
                        }
                        // Keep tiles a third wide when there are fewer than three.
                        ForEach(0..<max(0, 3 - RunText.cartTiles(run).count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 72)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard(radius: Metrics.radiusLarge, padding: 20)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your name")
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
            TextField("First name", text: $name)
                .font(.system(size: 17))
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .disabled(joined != nil)
                .onChange(of: name) { _, new in
                    if new.count > 24 { name = String(new.prefix(24)) }
                }
                .dibsInput()
                .contentShape(Rectangle())
                .onTapGesture { if joined == nil { nameFocused = true } }
        }
    }

    private var hold: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your hold")
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
            Text(Money.whole(capCents))
                .font(.display(72))
                .tracking(-2)
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
            HStack(spacing: Metrics.space1) {
                ForEach(RunText.capOptions, id: \.self) { cents in
                    CapChip(cents: cents, selected: cents == capCents) {
                        guard joined == nil, !busy else { return }
                        withAnimation(.snappy) { capCents = cents }
                    }
                }
            }
            .padding(.vertical, 4)
            Text("Held on your card while the run is open. Only what you claim is captured; the rest is released when \(shopper?.name ?? "the shopper") checks out.")
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Color.bodyInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.space1) {
                Image(systemName: "creditcard")
                    .font(.system(size: 15))
                Text("Visa ending \(String(TestCard.approved.number.suffix(4)))")
                    .font(.system(size: 14))
            }
            .foregroundStyle(Color.muted)
            .padding(.top, 6)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let joined {
                Button("Start claiming") {
                    model.show(.claim(RunRef(runId: runId, personId: joined.personId)))
                }
                .buttonStyle(.dibs)
            } else {
                Button {
                    Task { await join() }
                } label: {
                    Text(busy ? "Joining…" : "Hold \(Money.whole(capCents)) and join")
                }
                .buttonStyle(.dibs)
                .disabled(busy || trimmedName.isEmpty)
            }
            Text("A Visa authorization, not a charge.")
                .font(.system(size: 12))
                .foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, Metrics.space1)
        .padding(.bottom, Metrics.space1)
        .background(Color.paper)
    }

    // MARK: actions

    private func load() async {
        if let previewRun {
            run = previewRun
            return
        }
        do {
            run = try await model.api.getRun(runId)
        } catch DibsError.server(let message, 404) {
            error = Self.sentence(message)
        } catch {
            // The run card falls back to plain copy; joining reports its own error.
        }
    }

    private func join() async {
        guard !trimmedName.isEmpty, !busy else { return }
        nameFocused = false
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await model.api.join(runId: runId, name: trimmedName, capCents: capCents, decline: decline)
            UserDefaults.standard.set(trimmedName, forKey: Self.nameKey)
            model.remember(RunRef(runId: runId, personId: result.personId))
            withAnimation(.snappy) { joined = result }
            UIAccessibility.post(notification: .announcement, argument: "You are in. \(HeldBadge.text(cents: result.auth.authorizedCents, approvalCode: nil)).")
            if let fresh = try? await model.api.getRun(runId) { run = fresh }
        } catch DibsError.server(let message, 409) where message == "declined" {
            self.error = "\(Self.sentence(message)). No hold was placed on your card."
        } catch {
            self.error = Self.sentence((error as? LocalizedError)?.errorDescription ?? "Could not join")
        }
    }

    /// The server says "declined"; show "Declined".
    static func sentence(_ message: String) -> String {
        RunText.capitalize(message)
    }
}

/// One hold choice: "$20", "$40", "$60".
private struct CapChip: View {
    let cents: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(Money.whole(cents))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(selected ? Color.white : Color.ink)
                .padding(.horizontal, 18)
                .frame(minWidth: 64, minHeight: Metrics.tap)
                .background(Capsule().fill(selected ? Color.ink : Color.card))
                .overlay(Capsule().strokeBorder(selected ? Color.ink : Color.lineStrong))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hold \(Money.whole(cents))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A product tile in "In the cart so far": the photo on its tint, or the first letter.
private struct CartTile: View {
    let chip: Chip

    var body: some View {
        ZStack {
            tileColor(id: chip.id)
            if let image = ChipPhoto.image(chip.photoUrl) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = ChipPhoto.remoteURL(chip.photoUrl) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { letter }
            } else {
                letter
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(chip.name)
    }

    private var letter: some View {
        Text(String(chip.name.prefix(1)))
            .font(.display(22))
            .foregroundStyle(Color.ink.opacity(0.55))
    }
}

/// Chip photos arrive as `data:` URLs (crops) or http(s) URLs.
enum ChipPhoto {
    static func image(_ photoUrl: String?) -> UIImage? {
        guard let photoUrl, photoUrl.hasPrefix("data:"), let comma = photoUrl.firstIndex(of: ","),
              let data = Data(base64Encoded: String(photoUrl[photoUrl.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }

    static func remoteURL(_ photoUrl: String?) -> URL? {
        guard let photoUrl, photoUrl.hasPrefix("https://") || photoUrl.hasPrefix("http://") else { return nil }
        return URL(string: photoUrl)
    }
}

#if DEBUG
#Preview("Join") {
    NavigationStack {
        JoinView(runId: PreviewData.runId, previewRun: PreviewData.run)
    }
    .environment(AppModel(defaults: UserDefaults(suiteName: "preview.join")!))
}

#Preview("Join, run not loaded") {
    NavigationStack {
        JoinView(runId: PreviewData.runId, previewRun: Run(id: PreviewData.runId, shopperId: "jake"))
    }
    .environment(AppModel(defaults: UserDefaults(suiteName: "preview.join2")!))
}
#endif
