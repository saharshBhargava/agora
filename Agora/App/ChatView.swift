import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Combine

struct ChatView: View {
    let workspace: ChatWorkspace
    @ObservedObject var agent: AgentCoordinator
    @ObservedObject var browser: BrowserSession
    var body: some View {
        ChatWorkspaceView(workspace: workspace, agent: agent, browser: browser, store: agent.conversations).tint(Color.ink)
    }
}

private struct ChatWorkspaceView: View {
    let workspace: ChatWorkspace
    @ObservedObject var agent: AgentCoordinator
    @ObservedObject var browser: BrowserSession
    @ObservedObject var store: ConversationStore
    @State private var history = false
    @State private var settings = false
    @State private var historySettings = false
    @State private var rename = false
    @State private var name = ""
    @State private var deleting = false
    @State private var controls = false
    @State private var position = CGPoint(x: 12, y: 12)
    @GestureState private var drag = CGSize.zero
    @FocusState private var composing: Bool
    private var expanded: Bool { browser.state.presentation == .expanded && browser.state.isOpen }
    var body: some View {
        GeometryReader { geometry in
            let sidePane = expanded && geometry.size.width >= 760
            let paneWidth = sidePane ? min(480, geometry.size.width * 0.46) : geometry.size.width
            let thumbnail = CGSize(width: min(184, geometry.size.width - 24), height: min(253, max(120, geometry.size.height - 24)))
            ZStack(alignment: .topLeading) {
                ChatConversationView(chat: store.current, agent: agent, browser: browser, settings: workspace.settings, composing: $composing)
                    .frame(width: sidePane ? geometry.size.width - paneWidth : geometry.size.width)
                    .accessibilityHidden(expanded && !sidePane)
                    .allowsHitTesting(!expanded || sidePane)
                // A single mounted representable owns the same WKWebView in all layouts.
                browserPanel
                    .frame(width: expanded ? paneWidth : thumbnail.width, height: expanded ? geometry.size.height : thumbnail.height)
                    .background(Color.card)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: expanded ? 0 : Metrics.radius).strokeBorder(Color.line))
                    .shadow(color: .black.opacity(expanded ? 0.04 : 0.16), radius: 14, y: 5)
                    .offset(x: expanded ? (sidePane ? geometry.size.width - paneWidth : 0) : clamped(position.x + drag.width, maximum: geometry.size.width - thumbnail.width - 12),
                            y: expanded ? 0 : clamped(position.y + drag.height, maximum: geometry.size.height - thumbnail.height - 12))
                    .opacity(browser.state.isOpen && browser.state.presentation != .hidden ? 1 : 0)
                    .allowsHitTesting(browser.state.isOpen && browser.state.presentation != .hidden)
                    .accessibilityHidden(!browser.state.isOpen || browser.state.presentation == .hidden)
                    .onChange(of: geometry.size) { _, size in
                        position.x = clamped(position.x, maximum: size.width - thumbnail.width - 12)
                        position.y = clamped(position.y, maximum: size.height - thumbnail.height - 12)
                    }
                    .environment(\.browserDragBounds, CGSize(width: geometry.size.width - thumbnail.width - 12, height: geometry.size.height - thumbnail.height - 12))
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.paper, for: .navigationBar)
        .tint(Color.ink)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Conversations", systemImage: "line.3.horizontal") { composing = false; history = true }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
            ToolbarItem(placement: .principal) { ChatTitle(chat: store.current, settings: workspace.settings, showSettings: { settings = true }) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Show Browser", systemImage: "globe") { browser.setPresentationFromUser(.thumbnail) }.disabled(!browser.state.isOpen)
                    Button("Rename chat", systemImage: "pencil") { name = store.current.title; rename = true }
                    Button("Archive chat", systemImage: "archivebox") { agent.archiveConversation(store.current) }
                    Button("New chat", systemImage: "square.and.pencil") { agent.newChat() }
                    Divider()
                    Button("Delete chat", systemImage: "trash", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Chat menu")
            }
        }
        .sheet(isPresented: $history, onDismiss: { if historySettings { historySettings = false; settings = true } }) {
            ChatHistorySheet(store: store, agent: agent, showSettings: { historySettings = true; history = false })
        }
        .sheet(isPresented: $settings) { SettingsSheet(workspace: workspace) }
        .alert("Rename chat", isPresented: $rename) { TextField("Chat title", text: $name); Button("Save") { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.current.title = String(name.prefix(100)) } }; Button("Cancel", role: .cancel) {} }
        .confirmationDialog("Delete this conversation?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete chat", role: .destructive) { agent.deleteConversation(store.current) } }
    }
    private func clamped(_ value: CGFloat, maximum: CGFloat) -> CGFloat { max(12, min(value, max(12, maximum))) }
    private var browserPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if expanded { Button { browser.humanInteraction(); browser.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(!browser.state.canGoBack || browser.state.busy).accessibilityLabel("Back") }
                else { Image(systemName: browser.state.privateMode ? "lock.shield" : "globe").foregroundStyle(Color.ink) }
                Text(expanded ? (browser.state.title.isEmpty ? browser.state.url?.host ?? "Browser" : browser.state.title) : browser.state.url?.host ?? "Shared browser").font(expanded ? .subheadline.weight(.semibold) : .caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if browser.state.busy || agent.running { ProgressView().controlSize(.mini).accessibilityLabel("Agent is working") }
                if expanded {
                    Button { browser.setPresentationFromUser(.thumbnail) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 44, height: 44) }.accessibilityLabel("Minimize browser")
                }
            }.padding(.horizontal, expanded ? 4 : 10).frame(minHeight: expanded ? 44 : 34)
            if browser.state.progress < 1 { ProgressView(value: browser.state.progress).frame(height: 2) }
            ZStack {
                BrowserView(session: browser, thumbnail: !expanded)
                if !expanded {
                    BrowserPreviewTouchLayer(position: $position, drag: $drag, controls: $controls)
                    if controls {
                        VStack(spacing: 8) {
                            Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { composing = false; browser.setPresentationFromUser(.expanded); controls = false }
                            Button("Hide", systemImage: "eye.slash") { browser.setPresentationFromUser(.hidden); controls = false }
                        }.buttonStyle(.dibs(.ink, fontSize: 15)).padding(10).background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius))
                    }
                }
                if browser.state.busy && expanded {
                    Color.black.opacity(0.08).contentShape(Rectangle()).onTapGesture { browser.humanInteraction() }
                    Text("Finishing browser action…").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink).padding(12).background(Color.card, in: Capsule()).overlay(Capsule().strokeBorder(Color.line)).allowsHitTesting(false)
                }
            }
            if expanded {
                HStack {
                    Button("Reload", systemImage: "arrow.clockwise") { browser.humanInteraction(); browser.webView.reload() }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(browser.state.busy)
                    Text(browser.state.url?.host ?? "Browser").font(.system(size: 13)).lineLimit(1).foregroundStyle(Color.muted)
                    Spacer()
                    if agent.paused { Button("Continue") { agent.resume() }.frame(minHeight: 44) }
                    Menu {
                        Button("Hide Browser", systemImage: "eye.slash") { browser.setPresentationFromUser(.hidden) }
                        Button(browser.state.privateMode ? "Leave private mode" : "Private mode", systemImage: "lock.shield") {
                            let wasPrivate = browser.state.privateMode
                            browser.humanInteraction(); browser.state.privateMode = true
                            if wasPrivate { Task { try? await browser.resume() } }
                        }
                        Button("Close Browser", role: .destructive) { agent.closeBrowser() }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Browser options")
                }.padding(.horizontal, 8)
            }
        }
    }
}

private struct BrowserDragBounds: EnvironmentKey { static let defaultValue = CGSize.zero }
private extension EnvironmentValues { var browserDragBounds: CGSize { get { self[BrowserDragBounds.self] } set { self[BrowserDragBounds.self] = newValue } } }
private struct BrowserPreviewTouchLayer: View {
    @Binding var position: CGPoint
    var drag: GestureState<CGSize>
    @Binding var controls: Bool
    @Environment(\.browserDragBounds) private var bounds
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture { controls.toggle() }
            .gesture(DragGesture(minimumDistance: 5).updating(drag) { value, state, _ in state = value.translation }.onEnded { value in
                position = CGPoint(x: max(12, min(position.x + value.translation.width, max(12, bounds.width))), y: max(12, min(position.y + value.translation.height, max(12, bounds.height))))
            })
            .accessibilityElement().accessibilityLabel("Live browser preview").accessibilityHint("Double tap for Expand and Hide controls.").accessibilityAddTraits(.isButton)
            .accessibilityAction { controls.toggle() }
    }
}

private struct ChatTitle: View {
    @ObservedObject var chat: ChatConversation
    @ObservedObject var settings: SettingsStore
    let showSettings: () -> Void
    var body: some View {
        Menu {
            if settings.demoCalendar?.isDemoAccount == true { Text("Dibs · Built-in sample responses") }
            else {
                ForEach(settings.modelConfiguration.profiles.filter { $0.capabilities.tools }) { profile in
                    Button(profile.name + " · " + profile.model) { settings.modelConfiguration.assignments[ModelFeature.chat.rawValue] = profile.id }
                }
            }
            Button("Model settings", systemImage: "slider.horizontal.3", action: showSettings)
        } label: {
            VStack(spacing: 2) {
                Text(chat.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                HStack(spacing: 4) {
                    Text(settings.demoCalendar?.isDemoAccount == true ? "Dibs · Sample" : (try? settings.modelConfiguration.profile(for: .chat).name) ?? "Choose model")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.font(.system(size: 12)).foregroundStyle(Color.muted)
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("\(chat.title). Selected model: \(settings.featureDescription(.chat))")
    }
}

private struct ChatConversationView: View {
    @ObservedObject var chat: ChatConversation
    @ObservedObject var agent: AgentCoordinator
    @ObservedObject var browser: BrowserSession
    @ObservedObject var settings: SettingsStore
    var composing: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var following = true
    @State private var dragging = false
    @State private var bottom: CGFloat = 0
    @State private var scrollFollowing = ChatScrollFollowing()
    private let bottomID = "conversation-bottom"
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: Metrics.space1) {
                                Text("Ask anything")
                                    .font(.display(32))
                                    .foregroundStyle(Color.ink)
                                    .accessibilityAddTraits(.isHeader)
                                Text("Plan a run, compare prices, or check what's running low at home.")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.bodyInk)
                                    .fixedSize(horizontal: false, vertical: true)
                                if settings.demoCalendar?.isDemoAccount == true {
                                    Text("Demo uses built-in sample responses, not live AI research.")
                                        .font(.system(size: 13)).foregroundStyle(Color.muted)
                                }
                            }
                            .padding(.top, Metrics.space2)
                        }
                        ForEach(chat.messages) { message in
                            ChatMessageView(message: message, approve: { agent.resolveApproval($0) }, retry: { text in
                                guard !agent.running else { return }
                                let retryDraft = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text
                                if agent.send(text, attachments: retryDraft ? chat.attachments : []), retryDraft { chat.draft = ""; chat.attachments = [] }
                            }, openBrowser: { composing.wrappedValue = false; browser.setPresentationFromUser(.expanded) })
                                .id(message.id)
                                .background(GeometryReader { reader in Color.clear.preference(key: ChatVisibleRowKey.self, value: [message.id: reader.frame(in: .named("transcript"))]) })
                        }
                        if agent.running { Label(agent.approval == nil ? agent.status : "Waiting for you", systemImage: "sparkle").font(.system(size: 15)).foregroundStyle(Color.muted).accessibilityLabel("Agent activity: \(agent.status)") }
                        if agent.paused { takeover }
                        Color.clear.frame(height: 1).id(bottomID)
                    }.scrollTargetLayout().padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16).frame(maxWidth: 760).frame(maxWidth: .infinity)
                        .background(GeometryReader { reader in Color.clear.preference(key: ChatBottomKey.self, value: ChatScrollMetrics(origin: reader.frame(in: .named("transcript")).minY, height: reader.size.height)) })
                }
                .id(dynamicTypeSize) // Reset lazy height estimates when the system text size changes.
                .coordinateSpace(name: "transcript")
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(ChatVisibleRowKey.self) { frames in
                    if !following, let first = frames.filter({ $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY }) { chat.scrollAnchor = first.key }
                }
                .task(id: dynamicTypeSize) {
                    // Allow Dynamic Type and lazy row measurements to settle before restoring the anchor.
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    if following { proxy.scrollTo(bottomID, anchor: .bottom) }
                    else if let anchor = chat.scrollAnchor { proxy.scrollTo(anchor, anchor: .top) }
                }
                .simultaneousGesture(DragGesture().onChanged { _ in dragging = true }.onEnded { _ in dragging = false; following = bottom - geometry.size.height < 120; chat.followsLatest = following })
                .onPreferenceChange(ChatBottomKey.self) { value in
                    bottom = value.bottom
                    scrollFollowing.follows = following
                    let shouldScroll = scrollFollowing.update(value, viewport: geometry.size.height, dragging: dragging)
                    following = scrollFollowing.follows; chat.followsLatest = following
                    if shouldScroll { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: chat.messages.count) { _, _ in if following { proxy.scrollTo(bottomID, anchor: .bottom) } }
                .onReceive(chat.messages.last?.$text.eraseToAnyPublisher() ?? Just("").eraseToAnyPublisher()) { _ in
                    if following && !dragging { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: geometry.size.height) { _, _ in if following { proxy.scrollTo(bottomID, anchor: .bottom) } }
                .onChange(of: agent.approval?.id) { _, _ in if following { proxy.scrollTo(bottomID, anchor: .bottom) } }
                .onChange(of: chat.id, initial: true) { _, _ in
                    following = chat.followsLatest; scrollFollowing = ChatScrollFollowing()
                    if following { proxy.scrollTo(bottomID, anchor: .bottom) }
                    else if let anchor = chat.scrollAnchor { proxy.scrollTo(anchor, anchor: .top) }
                }
                .overlay(alignment: .bottom) {
                    if !following {
                        Button { following = true; chat.followsLatest = true; withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) } } label: {
                            Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).padding(.horizontal, 16).frame(minHeight: 44).background(Color.card, in: Capsule()).overlay(Capsule().strokeBorder(Color.line))
                        }.padding(.bottom, 12)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ChatComposer(chat: chat, agent: agent, settings: settings, composing: composing) }
    }
    private var takeover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting for you", systemImage: "hand.raised").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
            Text(agent.status == "Waiting for you" ? "Complete the requested step in the browser, then continue. The assistant will read the updated page before acting." : agent.status).font(.system(size: 15)).foregroundStyle(Color.muted)
            HStack(spacing: Metrics.space1) {
                if browser.state.isOpen { Button("Open Browser") { composing.wrappedValue = false; browser.setPresentationFromUser(.expanded) }.buttonStyle(.dibs(.secondary, fontSize: 15)) }
                Button("Continue") { agent.resume() }.buttonStyle(.dibs(.ink, fontSize: 15))
            }
        }.dibsCard()
    }
}
private struct ChatBottomKey: PreferenceKey { static var defaultValue = ChatScrollMetrics(); static func reduce(value: inout ChatScrollMetrics, nextValue: () -> ChatScrollMetrics) { value = nextValue() } }

private struct ChatVisibleRowKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
