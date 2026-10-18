import SwiftUI

/// What the claim screen can do to the run. `ClaimView` wires these to the shared `RunStore` and `DibsAPI`;
/// previews pass stand-ins.
struct ClaimActions {
    /// Socket sends; false when the message could not go out (the store's `lastError` says why).
    var claim: @MainActor (String) -> Bool = { _ in true }
    var leave: @MainActor (String) -> Bool = { _ in true }
    var remove: @MainActor (String) -> Bool = { _ in true }
    /// Why the last send failed.
    var sendError: @MainActor () -> String? = { nil }
    /// Raises my hold to this many cents.
    var raise: @MainActor (Int) async throws -> Void = { _ in }
    /// Adds a wish; returns an error message or nil.
    var wish: @MainActor (String) async -> String? = { _ in nil }
}

/// The claimer's screen, live from the shared `RunStore` (canvas Claim.dc.html, web app/claim).
struct ClaimView: View {
    let ref: RunRef
    /// "See settle" once the shopper has checked out.
    var onSettle: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let run = store.run?.id == ref.runId ? store.run : nil
        Group {
            if let run, let me = run.person(ref.personId) {
                if me.isShopper {
                    shopperPanel
                } else {
                    ClaimScreen(
                        run: run,
                        me: me,
                        liveFrame: store.liveFrame,
                        identifyingRegion: store.identifyingRegion,
                        lastCallEndsAt: store.lastCallEndsAt,
                        connection: store.connection,
                        errorSeq: store.errorSeq,
                        lastError: store.lastError,
                        picks: ClaimLogic.usualPicks(saved: ClaimLogic.savedPicks(model.defaults), run: run),
                        actions: actions,
                        onSettle: onSettle
                    )
                    .onChange(of: ClaimLogic.seenNames(run), initial: true) { _, names in
                        ClaimLogic.recordSeen(names, defaults: model.defaults)
                    }
                }
            } else if run != nil {
                // Not in this run (a fresh install, or another phone's link): join it.
                ProgressView()
                    .dibsScreen()
                    .task { model.show(.join(runId: ref.runId, decline: false)) }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(store.connection == .refused ? "This run has ended" : "Loading the run")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dibsScreen()
            }
        }
        .task(id: ref) { model.enter(ref) }
    }

    private var actions: ClaimActions {
        let store = model.store
        let api = model.api
        let ref = ref
        return ClaimActions(
            claim: { store.claim($0) },
            leave: { store.leave($0) },
            remove: { store.remove($0) },
            sendError: { store.lastError },
            raise: { cents in _ = try await api.raise(runId: ref.runId, personId: ref.personId, capCents: cents) },
            wish: { name in
                do {
                    store.adopt(try await api.wish(runId: ref.runId, name: name, byPersonId: ref.personId))
                    return nil
                } catch {
                    return ClaimLogic.notice((error as? LocalizedError)?.errorDescription ?? "Could not add the wish")
                }
            }
        )
    }

    private var shopperPanel: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text("This page is for claimers.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.ink)
            Button("Go to the cart") { model.show(.shopper(ref)) }
                .buttonStyle(.dibs)
            Spacer()
        }
        .padding(20)
        .dibsScreen()
    }
}

/// The claim screen's content, driven by plain values so previews need no server.
struct ClaimScreen: View {
    let run: Run
    let me: Person
    var liveFrame: UIImage?
    var identifyingRegion: Box?
    var lastCallEndsAt: Date?
    var connection: RunStore.Connection = .live
    var errorSeq = 0
    var lastError: String?
    var picks: [String] = []
    var actions = ClaimActions()
    var onSettle: () -> Void = {}

    @State private var toast: Toast?
    @State private var overCap: Chip?
    @State private var raiseOff = false
    @State private var busy = false
    @State private var largeLive = false
    @State private var showWish = false
    @State private var trayTargeted = false

    private var shopper: Person? { run.shopper }
    private var open: Bool { run.isJoinable }
    private var shelf: [Chip] { ClaimLogic.shelfChips(run) }
    private var tray: [Chip] { ClaimLogic.trayChips(run, me: me.id) }
    private var trayTotal: Int { ClaimLogic.trayTotal(tray, me: me.id) }
    private var room: Int? { ClaimLogic.roomLeft(run: run, me: me.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    live
                    shareRow
                    banners
                    sectionHead
                    shelfRow
                }
                .padding(.bottom, Metrics.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .dropDestination(for: String.self) { items, _ in
                // A tray chip dragged out of the tray: leave it.
                let ids = items.compactMap(DragPayload.fromTray)
                for id in ids { if let chip = run.chip(id) { leave(chip) } }
                return !ids.isEmpty
            }
            .overlay(alignment: .bottom) {
                // The toast floats just above the tray.
                if let toast, overCap == nil {
                    UndoToast(toast: toast) { if self.toast == toast { self.toast = nil } }
                        .padding(.horizontal, Metrics.space2)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            Tray(chips: tray, people: run.people, me: me.id, targeted: trayTargeted) { leave($0) }
                .dropDestination(for: String.self) { items, _ in
                    trayTargeted = false
                    let ids = items.compactMap(DragPayload.fromShelf)
                    for id in ids { if let chip = run.chip(id) { tryClaim(chip) } }
                    return !ids.isEmpty
                } isTargeted: { trayTargeted = $0 }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
        .background(Color.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $overCap) { chip in
            let sheet = OverCapSheet(
                chip: chip,
                roomCents: room ?? 0,
                authorizedCents: me.authorizedCents ?? 0,
                raiseOff: raiseOff,
                busy: busy,
                onRaise: { Task { await raise(for: chip) } },
                onDismiss: { overCap = nil }
            )
            sheet
                .presentationDetents([.height(sheet.height), .large])
                .presentationBackground(Color.card)
                .presentationCornerRadius(28)
        }
        .navigationDestination(isPresented: $showWish) {
            WishView(picks: picks, shopperName: shopper?.name) { await actions.wish($0) }
        }
        .onChange(of: errorSeq) {
            if let lastError { toast = .notice(ClaimLogic.notice(lastError)) }
        }
    }

    // MARK: sections

    private var header: some View {
        let others = run.people.filter { $0.id != me.id }
        let stack = others + [me]
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .font(.display(22))
                    .tracking(-0.3)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Circle().fill(open ? Color.liveRed : Color.lineStrong).frame(width: 8, height: 8)
                    Text(ClaimLogic.statusLine(run))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                }
            }
            Spacer(minLength: 8)
            AvatarStack(list: stack, people: run.people, me: me.id, size: .sm, ring: .paper,
                        label: "In the run: \(stack.map(\.name).joined(separator: ", "))")
        }
        .padding(.horizontal, Metrics.space2)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var live: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LiveView(
                frame: liveFrame,
                shopperName: shopper?.name ?? "Shopper",
                highlight: ClaimLogic.highlight(chips: shelf, identifying: identifyingRegion,
                                                nowMs: context.date.timeIntervalSince1970 * 1000),
                height: largeLive ? 320 : 196
            )
        }
        .padding(.horizontal, Metrics.space2)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { largeLive.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Toggles the live view size")
    }

    private var shareRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your share")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                Text(Money.format(trayTotal))
                    .font(.display(52))
                    .tracking(-1.5)
                    .foregroundStyle(Color.meBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            if let held = me.authorizedCents {
                let over = (room ?? 0) < 0 || overCap != nil
                VStack(alignment: .trailing, spacing: 2) {
                    (Text(Money.format(held)).bold().foregroundColor(Color.ink) + Text(" held"))
                    (Text(Money.format(room ?? 0)).bold().foregroundColor(over ? Color.danger : Color.ink) + Text(" room left"))
                    if let code = me.approvalCode, !code.isEmpty {
                        Text("auth \(code)").font(.receipt(12))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var banners: some View {
        if connection == .reconnecting || connection == .connecting {
            Text(RunStore.reconnectingMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.muted)
                .padding(.horizontal, 20)
                .padding(.top, 4)
        }
        if run.state == .lastCall {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secs = lastCallEndsAt.map { max(0, Int($0.timeIntervalSince(context.date).rounded(.up))) } ?? 0
                banner {
                    Circle().fill(Color.liveRed).frame(width: 8, height: 8)
                    Text(ClaimLogic.lastCallLine(shopperName: shopper?.name, secs: secs))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.ink)
                }
            }
        } else if !open {
            banner {
                Text(ClaimLogic.closedLine(trayCents: trayTotal, count: tray.count))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("See settle", action: onSettle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Color.ink))
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .dibsCard(radius: 14, padding: 0)
            .padding(.horizontal, Metrics.space2)
            .padding(.top, 10)
    }

    private var sectionHead: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("In the cart")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Hold a chip, drag it to your tray")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muted)
            }
            Spacer()
            if open {
                Button { showWish = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("Wish").font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 18)
                    .frame(height: Metrics.tap)
                    .background(Capsule().fill(Color.card))
                    .overlay(Capsule().strokeBorder(Color.ink))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var shelfRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if shelf.isEmpty {
                    Text("Nothing in the cart yet. Items show up here as \(shopper?.name ?? "the shopper") adds them.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                        .frame(width: 300, alignment: .leading)
                        .padding(.vertical, Metrics.space2)
                }
                ForEach(shelf) { chip in shelfChip(chip) }
            }
            .padding(.leading, 20)
            .padding(.trailing, Metrics.space2)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func shelfChip(_ chip: Chip) -> some View {
        let card = ChipCard(
            chip: chip, people: run.people, me: me.id,
            canDelete: open && ClaimLogic.canDeleteWish(chip, me: me.id, meIsShopper: me.isShopper),
            onDelete: { deleteWish(chip) }
        )
        if chip.state == .wish || chip.state == .identifying {
            card
        } else {
            card
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture { tryClaim(chip) }
                .draggable(DragPayload.shelf(chip.id)) {
                    ChipCard(chip: chip, people: run.people, me: me.id)
                        .rotationEffect(.degrees(-3))
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: ClaimLogic.isMine(chip, me: me.id) ? "Leave" : "Claim") {
                    if ClaimLogic.isMine(chip, me: me.id) { leave(chip) } else { tryClaim(chip) }
                }
        }
    }

    // MARK: actions

    private func tryClaim(_ chip: Chip) {
        switch ClaimLogic.decide(chip, tray: tray, me: me.id, authorizedCents: me.authorizedCents, taxRate: run.taxRate) {
        case .claim:
            send(actions.claim(chip.id), label: "Claimed \(chip.name)") { _ = actions.leave(chip.id) }
        case .overCap:
            raiseOff = false
            overCap = chip
        case .alreadyMine, .notClaimable:
            break
        }
    }

    private func leave(_ chip: Chip) {
        guard ClaimLogic.isMine(chip, me: me.id) else { return }
        send(actions.leave(chip.id), label: "Left \(chip.name)") { _ = actions.claim(chip.id) }
    }

    private func deleteWish(_ chip: Chip) {
        if !actions.remove(chip.id) { showSendError() }
    }

    private func send(_ sent: Bool, label: String, undo: @escaping @MainActor () -> Void) {
        if sent {
            // Once the cart closes the server refuses; its reason arrives as a notice instead.
            if open { toast = Toast(label: label, undo: undo) }
        } else {
            showSendError()
        }
    }

    private func showSendError() {
        toast = .notice(actions.sendError() ?? RunStore.reconnectingMessage)
    }

    private func raise(for chip: Chip) async {
        guard let held = me.authorizedCents, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await actions.raise(ClaimLogic.raiseTarget(authorizedCents: held))
            overCap = nil
            // The raise was for this chip: claim it now that it fits.
            send(actions.claim(chip.id), label: "Claimed \(chip.name)") { _ = actions.leave(chip.id) }
        } catch DibsError.server(_, let status) where status == 403 {
            raiseOff = true
        } catch {
            overCap = nil
            toast = .notice(ClaimLogic.notice((error as? LocalizedError)?.errorDescription ?? "Could not raise your cap"))
        }
    }
}

#if DEBUG
#Preview("Claim, Priya") {
    NavigationStack {
        ClaimScreen(run: PreviewData.run, me: PreviewData.priya, picks: ["Bagels", "Bananas"])
    }
}

#Preview("Claim, live frame and outline") {
    var run = PreviewData.run
    run.chips.append(Chip(id: "new", name: "Kirkland Eggs", priceCents: 872, region: Box(x: 220, y: 140, w: 200, h: 160),
                          addedAt: Date().timeIntervalSince1970 * 1000))
    return NavigationStack {
        ClaimScreen(run: run, me: PreviewData.marcus, liveFrame: PreviewData.sampleFrame)
    }
}

#Preview("Claim, last call") {
    var run = PreviewData.run
    run.state = .lastCall
    return NavigationStack {
        ClaimScreen(run: run, me: PreviewData.priya, lastCallEndsAt: Date().addingTimeInterval(9), connection: .reconnecting)
    }
}

#Preview("Claim, closed") {
    var run = PreviewData.run
    run.state = .locked
    return NavigationStack {
        ClaimScreen(run: run, me: PreviewData.priya)
    }
}
#endif
