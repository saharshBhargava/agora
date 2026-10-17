import SwiftUI

struct ChatView: View {
    let workspace: ChatWorkspace
    @ObservedObject var agent: AgentCoordinator
    @ObservedObject var browser: BrowserSession
    @State private var draft = ""
    @State private var controls = false
    @State private var offset = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    conversation
                    // One representable stays mounted through every presentation state.
                    browserPanel
                        .frame(width: browser.state.presentation == .expanded ? geometry.size.width : min(184, geometry.size.width),
                               height: browser.state.presentation == .expanded ? geometry.size.height : min(280, geometry.size.height))
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: browser.state.presentation == .expanded ? 0 : 14))
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                        .offset(x: browser.state.presentation == .expanded ? 0 : max(0, min(offset.width + drag.width + 12, geometry.size.width - 196)),
                                y: browser.state.presentation == .expanded ? 0 : max(0, min(offset.height + drag.height + 12, geometry.size.height - 292)))
                        .opacity(browser.state.isOpen && browser.state.presentation != .hidden ? 1 : 0)
                        .allowsHitTesting(browser.state.isOpen && browser.state.presentation != .hidden)
                        .accessibilityHidden(!browser.state.isOpen || browser.state.presentation == .hidden)
                }
            }
            .navigationTitle("Agora")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("New chat", systemImage: "square.and.pencil") { agent.newChat(); offset = .zero }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .topBarTrailing) {
                    if browser.state.isOpen && browser.state.presentation == .hidden {
                        Button("Show Browser", systemImage: "globe") { browser.setPresentationFromUser(.thumbnail) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .overlay(alignment: .bottom) {
                if let approval = agent.approval {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(approval.title, systemImage: "hand.raised.fill").font(.headline)
                        ScrollView { Text(approval.detail).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 240)
                        HStack {
                            Button("Deny", role: .cancel) { agent.resolveApproval(false) }.buttonStyle(.bordered)
                            Spacer()
                            Button("Allow once") { agent.resolveApproval(true) }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding().shadow(radius: 8)
                }
            }
        }
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if agent.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "globe.americas.fill").font(.system(size: 42)).foregroundStyle(.teal)
                            Text("A conversation.\nA browser you share.").font(.largeTitle.bold())
                            Text("Ask Gemini to explore a page, find an answer, or help with a task. Open the live preview whenever you want to take over.").foregroundStyle(.secondary)
                            Text("Start by adding your Gemini API key in Settings.").font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 40)
                    }
                    ForEach(agent.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == "user" ? "YOU" : message.role == "assistant" ? "GEMINI" : "AGORA").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == "user" ? Color.teal.opacity(0.09) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding()
            }
            .onChange(of: agent.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            HStack {
                if agent.running { ProgressView().controlSize(.small) }
                Text(agent.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if agent.running { Button("Stop") { agent.stop() } }
                else if agent.paused { Button("Resume") { agent.resume() } }
            }
            HStack(alignment: .bottom) {
                TextField("Message Gemini", text: $draft, axis: .vertical)
                    .lineLimit(1...5).focused($composing).padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                Button {
                    let text = draft; draft = ""; composing = false; agent.send(text)
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                .disabled(agent.running || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
            }
        }.padding(.horizontal).padding(.vertical, 10).background(.bar)
    }
    private var browserPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: browser.state.privateMode ? "lock.shield" : "globe").foregroundStyle(.teal)
                Text(browser.state.url?.host ?? "Browser").font(.caption.bold()).lineLimit(1)
                Spacer(minLength: 0)
                if browser.state.presentation == .expanded {
                    Button { browser.setPresentationFromUser(.thumbnail) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.accessibilityLabel("Minimize browser")
                    Button { browser.setPresentationFromUser(.hidden) } label: { Image(systemName: "eye.slash") }.accessibilityLabel("Hide browser")
                }
            }.padding(10)
            ProgressView(value: browser.state.progress).frame(height: 2)
            ZStack {
                BrowserView(session: browser, thumbnail: browser.state.presentation != .expanded)
                if browser.state.presentation != .expanded {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { controls.toggle() }
                        .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in offset.width += value.translation.width; offset.height += value.translation.height })
                        .accessibilityLabel("Browser preview. Tap for controls.")
                    if controls {
                        VStack {
                            Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { composing = false; browser.setPresentationFromUser(.expanded); controls = false }
                            Button("Hide", systemImage: "eye.slash") { browser.setPresentationFromUser(.hidden); controls = false }
                        }.buttonStyle(.borderedProminent).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if browser.state.busy && browser.state.presentation == .expanded {
                    Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { browser.humanInteraction() }
                    Label("Finishing browser action…", systemImage: "hand.raised").padding().background(.regularMaterial, in: Capsule())
                }
            }
            if browser.state.presentation == .expanded {
                HStack {
                    Button { browser.humanInteraction(); browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.state.canGoBack).accessibilityLabel("Back")
                    Button { browser.humanInteraction(); browser.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.state.canGoForward).accessibilityLabel("Forward")
                    Button { browser.humanInteraction(); browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                    Spacer()
                    Toggle("Private", isOn: Binding(get: { browser.state.privateMode }, set: { enabled in
                        browser.humanInteraction(); browser.state.privateMode = true
                        if !enabled { Task { try? await browser.resume() } }
                    })).toggleStyle(.button)
                    Button("Close", role: .destructive) { agent.closeBrowser() }
                }.padding(10).disabled(browser.state.busy)
            }
            HStack(spacing: 6) {
                if agent.running { ProgressView().controlSize(.mini) }
                Text(agent.running ? agent.status : browser.state.status)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(8)
        }
    }
}
