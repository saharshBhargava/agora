import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    @ObservedObject var chat: ChatConversation
    @ObservedObject var agent: AgentCoordinator
    @ObservedObject var settings: SettingsStore
    var composing: FocusState<Bool>.Binding
    static let suggestions = ["What’s running low?", "Show my shopping lists", "Add something to my wishlist", "Plan a shopping trip"]
    @StateObject private var dictation = ChatDictation()
    @State private var photo: PhotosPickerItem?
    @State private var photoPicker = false
    @State private var files = false
    @State private var importing = false
    @State private var error: String?
    @State private var preview: ChatAttachment?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.space1) {
                        ForEach(chat.attachments) { attachment in attachmentChip(attachment) }
                    }
                }
                Text(settings.usesBuiltInSamples ? "Demo ignores attachments; sample responses only." : "Attachments are sent to your selected model. PDFs share extracted text.").font(.system(size: 13)).foregroundStyle(Color.muted)
            }
            if importing { ProgressView("Preparing attachment…").font(.system(size: 13)).foregroundStyle(Color.muted) }
            if let error = error ?? dictation.error {
                HStack(alignment: .top) { ErrorText(message: error); Button("Dismiss") { self.error = nil; dictation.error = nil }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).frame(minHeight: 44) }
            }
            if dictation.recording { Label("Listening · tap the microphone to finish", systemImage: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink) }
            if chat.draft.isEmpty, chat.attachments.isEmpty, !agent.running, !agent.paused, !dictation.recording {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ChatComposer.suggestions, id: \.self) { suggestion in
                            ShelfChip(title: suggestion, selected: false) {
                                chat.draft = suggestion
                                composing.wrappedValue = true
                            }
                            .accessibilityHint("Fills the message field for you to edit and send")
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Metrics.space1) {
                Menu {
                    Button("Photo library", systemImage: "photo") { photoPicker = true }
                    Button("Choose file", systemImage: "doc") { files = true }
                } label: {
                    Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.ink)
                        .frame(width: 52, height: 52)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong))
                }.disabled(chat.attachments.count >= 4 || importing).accessibilityLabel("Attach image or file")
                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Ask anything", text: $chat.draft, axis: .vertical)
                        .font(.system(size: 16)).foregroundStyle(Color.ink)
                        .lineLimit(1...6).focused(composing)
                        .frame(minHeight: 52)
                        .accessibilityLabel("Ask anything")
                    Button {
                        if dictation.recording { dictation.stop() }
                        else {
                            let prefix = chat.draft, id = chat.id
                            Task { await dictation.start { value in guard chat.id == id else { return }; chat.draft = prefix + (prefix.isEmpty ? "" : " ") + value } }
                        }
                    } label: { Image(systemName: dictation.recording ? "mic.fill" : "mic").font(.system(size: 18)).frame(width: 40, height: 52).foregroundStyle(dictation.recording ? Color.ink : Color.muted) }.accessibilityLabel(dictation.recording ? "Stop dictation" : "Dictate message")
                }
                .padding(.leading, Metrics.space2).padding(.trailing, 2)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong))
                if agent.running {
                    Button { agent.stop(); dictation.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white).frame(width: 52, height: 52).background(Color.ink, in: Circle()) }.accessibilityLabel("Stop response")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up").font(.system(size: 20, weight: .bold)).foregroundStyle(.white).frame(width: 52, height: 52).background(Color.ink.opacity(canSend ? 1 : 0.35), in: Circle()).contentShape(Circle()) }.disabled(!canSend).accessibilityLabel("Send message")
                }
            }
            if chat.draft.utf8.count > 15000 {
                Text("\(chat.draft.utf8.count)/16000").font(.system(size: 13)).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .tint(Color.ink)
        .padding(.horizontal, 16).padding(.top, Metrics.space1).padding(.bottom, Metrics.space1)
        .background(Color.paper, ignoresSafeAreaEdges: .bottom)
        .photosPicker(isPresented: $photoPicker, selection: $photo, matching: .images)
        .fileImporter(isPresented: $files, allowedContentTypes: [.image, .pdf, .text], allowsMultipleSelection: true) { result in
            let id = chat.id
            Task { @MainActor in
                importing = true; defer { importing = false }
                do {
                    let urls = try result.get()
                    guard urls.count + chat.attachments.count <= 4 else { throw BrowserError("attachment_limit", "Attach up to four files per message.") }
                    let values = try await Task.detached(priority: .userInitiated) { try urls.map(ChatAttachment.read) }.value
                    guard chat.id == id else { return }; chat.attachments.append(contentsOf: values)
                } catch { self.error = error.localizedDescription }
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            let id = chat.id; importing = true; defer { importing = false; self.photo = nil }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw BrowserError("photo_unavailable", "The photo could not be loaded. Try again.") }
                try Task.checkCancellation()
                let item = try ChatAttachment.photo(data)
                guard chat.id == id, chat.attachments.count < 4 else { return }; chat.attachments.append(item)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onChange(of: chat.id) { _, _ in dictation.stop(); error = nil; photo = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dictation.stop() } }
        .onDisappear { dictation.stop() }
        .sheet(item: $preview) { attachment in NavigationStack { ChatAttachmentPreview(attachment: attachment).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } } }.tint(Color.ink) }
    }
    private func attachmentChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 6) {
            Button { preview = attachment } label: {
                HStack(spacing: 8) {
                    Group {
                        if let image = attachment.image { Image(uiImage: image).resizable().scaledToFill() }
                        else { ZStack { tileColor(id: attachment.id.uuidString); Image(systemName: "doc.text").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink) } }
                    }.frame(width: 36, height: 36).clipped().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(attachment.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1).frame(maxWidth: 120)
                }
            }.accessibilityLabel("Preview \(attachment.name)")
            Button { chat.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.muted).frame(width: 44, height: 44) }.accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, 6)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.line))
    }
    private var canSend: Bool { (!chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty) && chat.draft.utf8.count <= 16000 && !importing }
    private func send() {
        dictation.stop()
        if agent.send(chat.draft, attachments: chat.attachments) { chat.draft = ""; chat.attachments = []; composing.wrappedValue = false }
    }
}

struct ChatHistorySheet: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var agent: AgentCoordinator
    let showSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var archived = false
    @State private var renaming: ChatConversation?
    @State private var deleting: ChatConversation?
    @State private var name = ""
    private var visible: [ChatConversation] {
        store.conversations.filter { ChatHistoryRow.matches($0, search: search, showArchived: archived) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your chats").font(.display(32)).tracking(-0.5).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                        Text("Conversations and drafts stay on this device for this signed-in session. Signing out clears them.")
                            .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Metrics.space1) {
                        Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.muted)
                        TextField("Search conversations", text: $search).font(.system(size: 16)).foregroundStyle(Color.ink)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.muted).frame(width: 36, height: 44) }.accessibilityLabel("Clear search")
                        }
                    }.padding(.leading, Metrics.space2).padding(.trailing, 4).frame(minHeight: 52)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong))
                    HStack {
                        DibsSectionHeader("Conversations")
                        Button { archived.toggle() } label: {
                            Label("Show archived", systemImage: archived ? "checkmark" : "archivebox").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(archived ? Color.white : Color.ink)
                                .padding(.horizontal, 12).frame(minHeight: 32)
                                .background(archived ? Color.ink : Color.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(archived ? Color.ink : Color.lineStrong))
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityAddTraits(archived ? .isSelected : [])
                    }
                    VStack(spacing: Metrics.space1) {
                        ForEach(store.conversations) { chat in
                            ChatHistoryRow(chat: chat, search: search, showArchived: archived, selected: chat.id == store.current.id,
                                           select: { agent.selectConversation(chat); dismiss() }, rename: { name = chat.title; renaming = chat }, archive: { agent.archiveConversation(chat) }, delete: { deleting = chat })
                        }
                        if visible.isEmpty {
                            Text(search.isEmpty ? (archived ? "No archived chats." : "Your chats will show up here.") : "No chats match that search.")
                                .font(.system(size: 14)).foregroundStyle(Color.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(minHeight: 52)
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                    }
                    Button(action: showSettings) {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.ink).frame(width: 36, height: 36)
                                .background(Color.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text("Settings").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lineStrong)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).dibsCard(padding: 12)
                }
                .padding(.horizontal, 20).padding(.top, Metrics.space1).padding(.bottom, Metrics.space3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button { agent.newChat(); dismiss() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .buttonStyle(.dibs)
                    .padding(.horizontal, 20).padding(.vertical, Metrics.space1).background(Color.paper)
            }
            .dibsScreen()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) { TextField("Title", text: $name); Button("Save") { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { renaming?.title = String(name.prefix(100)) }; renaming = nil }; Button("Cancel", role: .cancel) { renaming = nil } }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) { Button("Delete chat", role: .destructive) { if let deleting { agent.deleteConversation(deleting) }; deleting = nil } }
        }
        .tint(Color.ink)
    }
}
private struct ChatHistoryRow: View {
    @ObservedObject var chat: ChatConversation
    let search: String
    let showArchived: Bool
    let selected: Bool
    let select: () -> Void
    let rename: () -> Void
    let archive: () -> Void
    let delete: () -> Void
    @MainActor static func matches(_ chat: ChatConversation, search: String, showArchived: Bool) -> Bool {
        chat.archived == showArchived && (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search) || chat.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(search) }))
    }
    var body: some View {
        if Self.matches(chat, search: search, showArchived: showArchived) {
            HStack(spacing: 4) {
                Button(action: select) {
                    HStack(spacing: 12) {
                        Text(String(chat.title.prefix(1)).uppercased()).font(.display(20)).foregroundStyle(Color.ink)
                            .frame(width: 44, height: 44).background(tileColor(id: chat.id.uuidString), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chat.title).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink).lineLimit(2)
                            Text(chat.draft.isEmpty ? chat.messages.last(where: { !$0.text.isEmpty })?.text ?? "Start a conversation" : "Draft: \(chat.draft)").font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    Button("Rename", systemImage: "pencil", action: rename)
                    Button(chat.archived ? "Unarchive" : "Archive", systemImage: "archivebox", action: archive)
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.muted).frame(width: 40, height: 44) }
                    .accessibilityLabel("Options for \(chat.title)")
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(selected ? Color.ink : Color.line, lineWidth: selected ? 1.5 : 1))
            .contextMenu { Button("Rename", systemImage: "pencil", action: rename); Button(chat.archived ? "Unarchive" : "Archive", systemImage: "archivebox", action: archive); Button("Delete", systemImage: "trash", role: .destructive, action: delete) }
            .accessibilityAction(named: "Rename", rename).accessibilityAction(named: chat.archived ? "Unarchive" : "Archive", archive).accessibilityAction(named: "Delete", delete)
        }
    }
}
