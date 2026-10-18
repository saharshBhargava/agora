import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    @ObservedObject var chat: ChatConversation
    @ObservedObject var agent: AgentCoordinator
    @ObservedObject var settings: SettingsStore
    var composing: FocusState<Bool>.Binding
    @StateObject private var dictation = ChatDictation()
    @State private var photo: PhotosPickerItem?
    @State private var photoPicker = false
    @State private var files = false
    @State private var importing = false
    @State private var error: String?
    @State private var preview: ChatAttachment?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chat.attachments) { attachment in
                            HStack(spacing: 6) {
                                Button { preview = attachment } label: {
                                    HStack(spacing: 8) {
                                        if let image = attachment.image { Image(uiImage: image).resizable().scaledToFill().frame(width: 40, height: 40).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                                        else { Image(systemName: "doc.text").frame(width: 28) }
                                        Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 120)
                                    }
                                }.accessibilityLabel("Preview \(attachment.name)")
                                Button { chat.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.accessibilityLabel("Remove \(attachment.name)")
                            }.padding(.leading, 8).background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Text(settings.demoCalendar?.isDemoAccount == true ? "Demo ignores attachments; sample responses only." : "Attachments are sent to your selected model. PDFs share extracted text.").font(.caption2).foregroundStyle(.secondary)
            }
            if importing { ProgressView("Preparing attachment…").font(.caption) }
            if let error = error ?? dictation.error {
                HStack(alignment: .top) { Text(error).font(.caption).foregroundStyle(.red); Spacer(); Button("Dismiss") { self.error = nil; dictation.error = nil }.font(.caption).frame(minHeight: 44) }
            }
            if dictation.recording { Label("Listening · tap the microphone to finish", systemImage: "waveform").font(.caption).foregroundStyle(Color.agoraAccent) }
            if chat.draft.isEmpty, chat.attachments.isEmpty, !agent.running, !agent.paused, !dictation.recording {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["What’s running low?", "Show my shopping lists", "Add something to my wishlist", "Plan a shopping trip"], id: \.self) { suggestion in
                            Button {
                                chat.draft = suggestion
                                composing.wrappedValue = true
                            } label: {
                                Text(suggestion)
                                    .font(.subheadline.weight(.medium))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .foregroundStyle(Color.agoraAccent)
                                    .background(Color.agoraAccent.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Fills the message field for you to edit and send")
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                Menu {
                    Button("Photo library", systemImage: "photo") { photoPicker = true }
                    Button("Choose file", systemImage: "doc") { files = true }
                } label: { Image(systemName: "plus").font(.system(size: 19)).frame(width: 44, height: 44) }.disabled(chat.attachments.count >= 4 || importing).accessibilityLabel("Attach image or file")
                TextField("Message Agora", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...6).focused(composing)
                    .padding(.vertical, 11).padding(.horizontal, 4)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Message Agora")
                Button {
                    if dictation.recording { dictation.stop() }
                    else {
                        let prefix = chat.draft, id = chat.id
                        Task { await dictation.start { value in guard chat.id == id else { return }; chat.draft = prefix + (prefix.isEmpty ? "" : " ") + value } }
                    }
                } label: { Image(systemName: dictation.recording ? "mic.fill" : "mic").font(.system(size: 19)).frame(width: 44, height: 44).foregroundStyle(dictation.recording ? Color.agoraAccent : .secondary) }.accessibilityLabel(dictation.recording ? "Stop dictation" : "Dictate message")
                if agent.running {
                    Button { agent.stop(); dictation.stop() } label: { Label("Stop", systemImage: "stop.fill").font(.subheadline.bold()).padding(.horizontal, 12).frame(height: 44).background(.primary, in: Capsule()).foregroundStyle(Color.agoraBackground) }.accessibilityLabel("Stop response")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).frame(width: 32, height: 32).foregroundStyle(.white).background(canSend ? Color.agoraAction : Color.secondary.opacity(0.3), in: Circle()).frame(width: 44, height: 44).contentShape(Rectangle()) }.disabled(!canSend).accessibilityLabel("Send message")
                }
            }.padding(.horizontal, 4).padding(.vertical, 2).background(Color.agoraSurface, in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.08)))
            if chat.draft.utf8.count > 15000 {
                Text("\(chat.draft.utf8.count)/16000").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 16).background(.bar)
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
        .sheet(item: $preview) { attachment in NavigationStack { ChatAttachmentPreview(attachment: attachment).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } } } }
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
    var body: some View {
        NavigationStack {
            AgoraList {
                Button("New chat", systemImage: "square.and.pencil") { agent.newChat(); dismiss() }.padding(.vertical, 8)
                Section {
                    Toggle("Show archived", isOn: $archived)
                    ForEach(store.conversations) { chat in
                        ChatHistoryRow(chat: chat, search: search, showArchived: archived, selected: chat.id == store.current.id,
                                       select: { agent.selectConversation(chat); dismiss() }, rename: { name = chat.title; renaming = chat }, archive: { agent.archiveConversation(chat) }, delete: { deleting = chat })
                    }
                } header: { Text("Conversations") } footer: { Text("Conversations and drafts stay on this device for this signed-in session. Signing out clears them.") }
                Button("Settings", systemImage: "gearshape", action: showSettings)
            }
            .searchable(text: $search, prompt: "Search conversations")
            .agoraSurface()
            .navigationTitle("Your chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) { TextField("Title", text: $name); Button("Save") { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { renaming?.title = String(name.prefix(100)) }; renaming = nil }; Button("Cancel", role: .cancel) { renaming = nil } }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) { Button("Delete chat", role: .destructive) { if let deleting { agent.deleteConversation(deleting) }; deleting = nil } }
        }
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
    var body: some View {
        if chat.archived == showArchived && (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search) || chat.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(search) })) {
            Button(action: select) {
                HStack { VStack(alignment: .leading, spacing: 5) { Text(chat.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2); Text(chat.draft.isEmpty ? chat.messages.last(where: { !$0.text.isEmpty })?.text ?? "Start a conversation" : "Draft: \(chat.draft)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(Color.agoraAccent) } }.padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Rename", systemImage: "pencil", action: rename); Button(chat.archived ? "Unarchive" : "Archive", systemImage: "archivebox", action: archive); Button("Delete", systemImage: "trash", role: .destructive, action: delete) }
            .swipeActions { Button("Delete", role: .destructive, action: delete); Button(chat.archived ? "Unarchive" : "Archive", action: archive).tint(Color.agoraAccent) }
            .accessibilityAction(named: "Rename", rename).accessibilityAction(named: chat.archived ? "Unarchive" : "Archive", archive).accessibilityAction(named: "Delete", delete)
        }
    }
}
