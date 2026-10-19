import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The shopper's screen (Shopper.dc.html, Fixes.dc.html, LastCall.dc.html; web/app/shopper): live
/// camera of the cart (streamed to housemates, watched on-device for new items) over a paper sheet
/// with the covered total, the per-person bar and the cart rows. Rows can be swiped or dragged onto
/// the camera to remove them (5 s undo) and tapped to fix their name and price. Last call puts a
/// countdown band over the camera; lock shows the unclaimed list and the way to the receipt camera.
///
/// Light only: ink on paper, white on the dark camera.
struct ShopperView: View {
    let store: RunStore
    let api: DibsAPI
    let runId: String
    let personId: String
    /// Opens the receipt camera ("I've paid · snap the receipt"). The routed screen passes
    /// `model.openReceipt(ref)`; nil (the debug auto-shop root, which has no navigation) hides it.
    let onSnapReceipt: (() -> Void)?
    /// Called after "Leave the cart?" is confirmed and the camera and price worker are stopped. The
    /// routed screen goes Home; nil (the debug auto-shop root) just stops.
    let onLeave: (() -> Void)?
    /// Made once in `.task`, not in `init`: DibsRootView re-creates this view on every run broadcast, and a
    /// camera built in `init` would churn an AVCaptureSession each time.
    @State private var camera: ShopperCamera?
    /// Finds QFC prices for unpriced chips with the in-app browser while this shopper is in the run.
    @State private var priceWorker = PriceWorker()

    @State private var fixing: FixTarget?
    /// Counts on their way to the server, by chip id: the row shows it and its stepper waits.
    @State private var pendingQuantity: [String: Int] = [:]
    @State private var confirmLeave = false
    /// Chips already seen removed; a chip newly removed (by anyone, the camera watcher too) gets the undo.
    @State private var removedIds: Set<String>?
    /// Re-evaluates rows while a named item waits for its price (shows at 5 s, "Add price" at 20 s).
    @State private var clock = Date()
    /// "Removed 2% Milk · Undo · 5s" (the shared UndoToast).
    @State private var toast: Toast?
    @State private var kept: Set<String> = []
    /// "Counted twice?" cards the shopper kept or undid (`ShopperLogic.countKey`).
    @State private var handledCounts: Set<String> = []
    @State private var notice: String?
    @State private var busy = false
    @State private var actionError: String?
    /// The row being dragged with the system drag (kept until the next drag; `dragActive` drives the UI).
    @State private var dragged: Chip?
    /// A row drag is over the screen: the remove zone shows.
    @State private var dragActive = false
    /// The dragged row is over the camera (drop removes it).
    @State private var dragOverCamera = false
    /// When the last row drag started, and whether the drop target has heard from it since. A drag
    /// the system cancels at once (a hold released without moving) sends no callback, so a watchdog
    /// hides the remove zone again.
    @State private var dragStartedAt: Date?
    @State private var dragSeen = false
    @State private var now = Date()
    /// Last call has no fixed length on the client: the first countdown value seen is the full bar.
    @State private var lastCallTotal = 0


    private struct FixTarget: Identifiable {
        let chip: Chip
        var focusPrice = false
        var id: String { chip.id }
    }

    private static let tip = "Tap the item on the screen to identify it"
    private static let space = "shopper"

    init(store: RunStore, api: DibsAPI, runId: String, personId: String,
         onSnapReceipt: (() -> Void)? = nil, onLeave: (() -> Void)? = nil) {
        self.store = store
        self.api = api
        self.runId = runId
        self.personId = personId
        self.onSnapReceipt = onSnapReceipt
        self.onLeave = onLeave
    }

    private var run: Run? { store.run }

    private var mode: ShopperLogic.Mode { ShopperLogic.mode(run?.state) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                switch mode {
                case .cart, .lastCall:
                    cartLayout(size: geo.size)
                case .locked:
                    lockedLayout
                case .closed:
                    closedPanel
                }
            }
            .coordinateSpace(name: Self.space)
            // Rows are dragged with the system drag (it leaves the list's swipe-to-remove alone). The
            // whole screen is the drop target so the drag's end is always seen; only a drop over the
            // camera removes the row.
            .onDrop(of: [.plainText], delegate: RemoveDrop(
                cameraHeight: cameraFrameHeight ?? 0, dragged: dragged,
                active: $dragActive, overCamera: $dragOverCamera, seen: $dragSeen, onRemove: { remove($0) }))
            .task(id: dragStartedAt) {
                guard dragStartedAt != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled, !dragSeen { dragActive = false; dragOverCamera = false }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    UndoToast(toast: toast) { clearUndo(toast) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, mode == .cart ? 84 : 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast)
        }
        .background(Color.paper.ignoresSafeArea())
        // A paper bar on top: the app is light only, so the status bar draws in ink and must not sit
        // over the dark camera (ink on dark was unreadable). The camera starts under the bar.
        .navigationTitle(run?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        // The way out is the close button, which asks first (leaving stops the stream).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { confirmLeave = true } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                }
                .accessibilityLabel("Leave the cart")
            }
            // Invite more housemates while streaming: same link and text as the start screen's share button.
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: StartLogic.shareText(title: run?.title ?? "the run", link: api.joinLink(runId: runId)),
                          subject: Text(run?.title ?? "Dibs run")) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                }
                .accessibilityLabel("Share the join link")
            }
        }
        .confirmationDialog("Leave the cart? Housemates will stop seeing your stream.",
                            isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { leave() }
            Button("Stay", role: .cancel) {}
        }
        .preferredColorScheme(.light)
        .sheet(item: $fixing) { target in
            FixChipSheet(chip: target.chip, focusPrice: target.focusPrice,
                         showsQuantity: ShopperLogic.canAdjustQuantity(target.chip, runState: run?.state),
                         onSave: { name, cents, quantity in save(target.chip, name: name, cents: cents, quantity: quantity) },
                         onCancel: { fixing = nil },
                         onRemove: ShopperLogic.canRemoveFromSheet(target.chip, runState: run?.state)
                            ? { fixing = nil; remove(target.chip) } : nil)
                .presentationDetents([.height(500)])
                .presentationBackground(Color.paper)
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: dragOverCamera) { _, over in over }
        .task {
            store.connect(runId: runId, personId: personId)
            priceWorker.start(api: api, runId: runId)
            // The phone rides clipped to the cart: keep it from auto-locking while it streams.
            UIApplication.shared.isIdleTimerDisabled = true
            let cam = camera ?? ShopperCamera(store: store, api: api, runId: runId)
            if camera == nil { camera = cam }
            cam.runStateChanged(store.run?.state)
            await cam.start()
        }
        .onDisappear {
            camera?.stop()
            priceWorker.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: store.run?.state, initial: true) { _, state in camera?.runStateChanged(state) }
        .onChange(of: store.connection, initial: true) { _, c in DibsLog.event("socket \(c)") }
        .onChange(of: store.lastError) { _, e in if let e { DibsLog.event("store error: \(e)") } }
        .onChange(of: "\(store.errorSeq)|\(store.lastError ?? "")") { _, _ in
            if let e = store.lastError, let n = ShopperLogic.notice(forError: e) { notice = n }
        }
        .onChange(of: camera?.lastAddError) { _, e in if let e = e ?? nil { notice = e } }
        .onChange(of: store.run?.chips, initial: true) { _, chips in
            guard let chips else { return }
            let r = ShopperLogic.removals(previous: removedIds, chips: chips)
            removedIds = r.ids
            if let chip = r.new.last(where: { !$0.name.isEmpty }) { showUndo(chip) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if ShopperLogic.needsTick(store.run?.chips ?? [], now: clock) { clock = Date() }
            }
        }
        // A new identify attempt (a region) clears the hint.
        .onChange(of: store.identifyingRegion) { _, r in if r != nil { notice = nil } }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
        .task(id: run?.state == .lastCall) {
            guard run?.state == .lastCall else { lastCallTotal = 0; return }
            while !Task.isCancelled {
                now = Date()
                if let ends = store.lastCallEndsAt {
                    lastCallTotal = max(lastCallTotal, ShopperLogic.secondsLeft(until: ends, now: now))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: open cart and last call

    private func cartLayout(size: CGSize) -> some View {
        let camHeight = max(220, size.height * 0.42)
        return VStack(spacing: 0) {
            cameraArea(height: camHeight)
                .frame(height: camHeight)
            sheet
                .padding(.top, -28)
        }
    }

    private var sheet: some View {
        let chips = run?.chips ?? []
        let rows = ShopperLogic.rows(chips, now: clock)
        let dupes = ShopperLogic.duplicates(chips, kept: kept, now: clock)
        let counted = ShopperLogic.countedAgain(chips, handled: handledCounts, now: Date())
            .filter { ShopperLogic.canAdjustQuantity($0, runState: run?.state) }
        let people = run?.people ?? []
        let cover = ShopperLogic.coverage(people: people, chips: chips)
        return VStack(spacing: 0) {
            List {
                Group {
                    coveredHeader(cover, people: people, chips: chips)
                        .padding(.top, 20)
                    ForEach(dupes) { chip in
                        DuplicateCard(chip: chip,
                                      onKeep: { kept.insert(chip.id) },
                                      onRemove: { remove(chip) })
                    }
                    ForEach(counted) { chip in
                        DuplicateCard(chip: chip, title: "Counted twice?", line: ShopperLogic.countedAgainLine(chip),
                                      keepTitle: "Keep ×\(chip.quantity)", removeTitle: ShopperLogic.countedAgainUndoTitle(chip),
                                      onKeep: { handledCounts.insert(ShopperLogic.countKey(chip)) },
                                      onRemove: {
                                          handledCounts.insert(ShopperLogic.countKey(chip))
                                          setQuantity(chip, to: chip.quantity - 1)
                                      })
                    }
                    if rows.isEmpty {
                        Text("Nothing in the cart yet.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.muted)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(rows) { chip in row(chip) }
                    Color.clear.frame(height: toast == nil ? 4 : 70)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)

            if actionError != nil || mode == .cart {
                VStack(spacing: 8) {
                    if let actionError { ErrorText(message: actionError) }
                    if mode == .cart {
                        Button("Check out") { act { adopt(try await api.checkout(runId: runId, personId: personId)) } }
                            .buttonStyle(.dibs)
                            .disabled(busy || run == nil)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Color.paper)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func coveredHeader(_ cover: ShopperLogic.Coverage, people: [Person], chips: [Chip]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Covered by your housemates")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
                (Text(ShopperLogic.coveredLine(cover))
                    .font(.display(40))
                    .foregroundStyle(Color.ink)
                 + Text("  " + ShopperLogic.ofLine(cover))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.muted))
                    .monospacedDigit()
                    .accessibilityIdentifier("covered")
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(ShopperLogic.bar(people: people, chips: chips, me: personId), id: \.id) { piece in
                        Rectangle()
                            .fill(Color(hex: piece.colorHex))
                            .frame(width: geo.size.width * piece.fraction)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(Color.line)
            .clipShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel(ShopperLogic.barLabel(people: people, chips: chips))
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ chip: Chip) -> some View {
        let removable = ShopperLogic.isRemovable(chip)
        let view = CartRowView(chip: chip, people: run?.people ?? [], me: personId,
                               checking: priceWorker.status(for: chip.name), now: clock,
                               gaveUp: priceWorker.gaveUp(for: chip.name),
                               onAddPrice: { fixing = FixTarget(chip: chip, focusPrice: true) },
                               onQuantity: ShopperLogic.canAdjustQuantity(chip, runState: run?.state)
                                   ? { setQuantity(chip, to: $0) } : nil,
                               pendingQuantity: pendingQuantity[chip.id])
            .opacity(dragActive && dragged?.id == chip.id ? 0.3 : 1)
            .onTapGesture { if chip.state != .wish { fixing = FixTarget(chip: chip) } }
            .accessibilityAddTraits(chip.state != .wish ? .isButton : [])
            .accessibilityHint(chip.state != .wish ? "Fix the name or price" : "")
        if removable {
            view
                // Hold to drag onto the camera (system drag, so a sideways swipe stays the list's own).
                .onDrag {
                    dragged = chip
                    dragSeen = false
                    dragActive = true
                    dragStartedAt = Date()
                    return NSItemProvider(object: chip.id as NSString)
                } preview: {
                    CartRowView(chip: chip, people: run?.people ?? [], me: personId).frame(width: 340)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { remove(chip) } label: { Label("Remove", systemImage: "trash") }
                        .tint(Color.liveRed)
                }
                .accessibilityAction(named: "Remove from cart") { remove(chip) }
        } else {
            view
        }
    }

    /// Height of the camera area in the "shopper" space (rows dropped above this line are removed).
    private var cameraFrameHeight: CGFloat? {
        mode == .locked || mode == .closed ? nil : lastCameraHeight
    }
    @State private var lastCameraHeight: CGFloat = 0

    // MARK: camera

    private func cameraArea(height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Color.cameraDark
            switch camera?.status ?? .starting {
            case .denied:
                CameraOffPanel(title: "Camera is off",
                               message: "Dibs needs the camera to stream your cart to your housemates.",
                               showSettings: true)
                    .padding(.bottom, 28)
            case .unavailable:
                CameraOffPanel(title: "No camera", message: "This device has no rear camera.", showSettings: false)
                    .padding(.bottom, 28)
            case .starting, .running:
                if let camera {
                    GeometryReader { geo in
                        ZStack {
                            CameraPreview(session: camera.camera.session)
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { p in camera.tap(at: p, in: geo.size) }
                            outlines(camera, in: geo.size)
                        }
                    }
                }
            }
            if let hint {
                VStack {
                    Spacer()
                    Text(hint)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 96)
                }
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
            }
            streamingPill
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.trailing, 92) // the top-right corner is the price browser thumbnail's
                .padding(.top, 8)
            // Live thumbnail of the in-app browser while a price lookup runs (top-right corner is its own).
            PriceBrowserThumbnail(worker: priceWorker)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            scopeButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 16)
                .padding(.bottom, 40)
            if mode == .lastCall, let run {
                LastCallBand(run: run, secs: lastCallSecs, total: lastCallTotal, busy: busy) {
                    act { adopt(try await api.back(runId: runId, personId: personId)) }
                }
            }
            if dragActive {
                RemoveZone(isOver: dragOverCamera)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .onAppear { lastCameraHeight = height }
        .onChange(of: height) { _, h in lastCameraHeight = h }
    }

    private var lastCallSecs: Int {
        guard let ends = store.lastCallEndsAt else { return 0 }
        return ShopperLogic.secondsLeft(until: ends, now: now)
    }

    private var hint: String? {
        if store.connection == .reconnecting { return RunStore.reconnectingMessage }
        return notice
    }

    private var streaming: Bool {
        store.connection == .live && (run?.state == .open || run?.state == .lastCall)
    }

    private var streamingPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(streaming ? Color.liveRed : Color.white.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(ShopperLogic.streamingText(run))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.ink.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Bottom right of the camera (the top-right corner belongs to the price browser thumbnail).
    private var scopeButton: some View {
        Button { notice = Self.tip } label: {
            Image(systemName: "scope")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.ink.opacity(0.78), in: Circle())
        }
        .accessibilityLabel("Tap an item the camera missed")
    }

    @ViewBuilder
    private func outlines(_ camera: ShopperCamera, in size: CGSize) -> some View {
        if let frame = camera.streamSize {
            ForEach(Array(camera.pending.values.enumerated()), id: \.offset) { _, r in
                PulsingOutline(rect: ScanGeometry.viewRect(normalized: r, content: frame, in: size))
            }
            if let region = store.identifyingRegion, frame.width > 0, frame.height > 0 {
                let n = CGRect(x: region.x / frame.width, y: region.y / frame.height,
                               width: region.w / frame.width, height: region.h / frame.height)
                PulsingOutline(rect: ScanGeometry.viewRect(normalized: n, content: frame, in: size))
            }
        }
    }

    // MARK: locked and closed

    private var lockedLayout: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("LOCKED")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.white.opacity(0.8))
                Text("Head to the register. Claims are final now.")
                    .font(.display(26))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .background(Color.ink)

            ScrollView {
                VStack(spacing: 12) {
                    if let run {
                        UnclaimedList(
                            run: run,
                            busy: busy,
                            onPutBack: { id in act { adopt(try await api.putBack(runId: runId, chipId: id, personId: personId)) } },
                            onPaid: onSnapReceipt,
                            onBack: { act { adopt(try await api.back(runId: runId, personId: personId)) } }
                        )
                    }
                    if let actionError { ErrorText(message: actionError) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
        }
    }

    private var closedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The cart is closed")
                .font(.display(26))
                .foregroundStyle(Color.ink)
            Text("Settle is next: read the receipt, then everyone's share is captured from their hold.")
                .font(.system(size: 15))
                .foregroundStyle(Color.muted)
            if let onSnapReceipt {
                Button("Go to settle", action: onSnapReceipt).buttonStyle(.dibs)
            }
        }
        .dibsCard(radius: Metrics.radiusLarge, padding: 20)
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: actions

    /// Sends the removal; the undo toast comes from the chip turning `.removed` (same as a camera removal).
    private func remove(_ chip: Chip) {
        store.remove(chip.id)
    }

    private func showUndo(_ chip: Chip) {
        let countdown = UndoCountdown(chipId: chip.id, label: ShopperLogic.undoLabel(chip), startedAt: Date())
        toast = Toast(label: countdown.label, seconds: countdown.duration, undo: { undoRemove(countdown) })
    }

    /// Puts the row back while the server's 5 s window is open (later taps would only be refused).
    private func undoRemove(_ u: UndoCountdown) {
        guard !u.isExpired(at: Date()) else { return }
        store.undoRemove(u.chipId)
    }

    private func clearUndo(_ shown: Toast) {
        guard toast?.id == shown.id else { return }
        toast = nil
    }

    private func save(_ chip: Chip, name: String?, cents: Int?, quantity: Int?) {
        fixing = nil
        guard name != nil || cents != nil || quantity != nil else { return }
        act {
            if name != nil || cents != nil {
                adopt(try await api.fixChip(runId: runId, chipId: chip.id, personId: personId, name: name, priceCents: cents))
            }
            if let quantity {
                adopt(try await api.setQuantity(runId: runId, chipId: chip.id, personId: personId, quantity: quantity))
            }
        }
    }

    /// The row's − N +: shows the new count at once and waits for the server (one change per row at a
    /// time, so quick taps never race); the server's answer replaces the run either way.
    private func setQuantity(_ chip: Chip, to quantity: Int) {
        guard pendingQuantity[chip.id] == nil else { return }
        pendingQuantity[chip.id] = quantity
        actionError = nil
        Task { @MainActor in
            defer { pendingQuantity[chip.id] = nil }
            do {
                adopt(try await api.setQuantity(runId: runId, chipId: chip.id, personId: personId, quantity: quantity))
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong"
            }
        }
    }

    private func adopt(_ r: Run) { store.adopt(r) }

    private func leave() {
        camera?.stop()
        priceWorker.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        DibsLog.event("shopper left the cart")
        onLeave?()
    }

    private func act(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        actionError = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong"
            }
        }
    }
}

/// Drop target for a dragged cart row: the whole screen, so the drag's end is always seen. A drop
/// above `cameraHeight` (over the camera and its remove zone) removes the row.
private struct RemoveDrop: DropDelegate {
    let cameraHeight: CGFloat
    let dragged: Chip?
    @Binding var active: Bool
    @Binding var overCamera: Bool
    @Binding var seen: Bool
    let onRemove: (Chip) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragged != nil && info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) {
        seen = true
        active = true
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        seen = true
        overCamera = info.location.y < cameraHeight
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        active = false
        overCamera = false
    }
    func performDrop(info: DropInfo) -> Bool {
        defer { active = false; overCamera = false }
        guard let chip = dragged, info.location.y < cameraHeight else { return false }
        onRemove(chip)
        return true
    }
}

/// Last call over the camera: countdown, who sees it, the bar, "Back to cart".
private struct LastCallBand: View {
    let run: Run
    let secs: Int
    let total: Int
    let busy: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LAST CALL")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.white.opacity(0.8))
                Spacer()
                Text(ShopperLogic.clock(secs))
                    .font(.display(28))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Text(ShopperLogic.lastCallTitle(run))
                .font(.display(24))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                Capsule().fill(Color.white)
                    .frame(width: total > 0 ? geo.size.width * Double(secs) / Double(total) : 0)
                    .animation(.linear(duration: 0.25), value: secs)
            }
            .frame(height: 6)
            .background(Color(hex: 0x3A3733), in: Capsule())
            Button(action: onBack) {
                Text("Back to cart")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ink)
        .accessibilityElement(children: .contain)
    }
}

/// White outline that pulses over an item being identified.
private struct PulsingOutline: View {
    let rect: CGRect
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .allowsHitTesting(false)
    }
}

private struct CameraOffPanel: View {
    let title: String
    let message: String
    let showSettings: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.display(22)).foregroundStyle(.white)
            Text(message).font(.system(size: 15)).foregroundStyle(.white).multilineTextAlignment(.center)
            if showSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(Color.white, in: Capsule())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AVCaptureVideoPreviewLayer, aspect-fill, rotated to portrait.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = UIColor(Color.cameraDark)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
