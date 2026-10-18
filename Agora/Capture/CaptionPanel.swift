import SwiftUI

struct CaptionPanel: View {
    let item: CaptureItem
    let url: URL
    @ObservedObject var settings: SettingsStore
    @ObservedObject var library: MediaLibrary
    @ObservedObject var controller: CaptionController
    @State private var replacing = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Caption").font(.title3.bold())
            Picker("Style", selection: $controller.style) {
                ForEach(CaptionStyle.allCases) { style in Text(style.title).tag(style) }
            }.disabled(controller.busy)
            DisclosureGroup("Instructions") {
                TextField("Optional instructions", text: $controller.instruction, axis: .vertical)
                    .lineLimit(2...4).disabled(controller.busy)
            }
            Text(controller.busy ? controller.modelDescription : settings.featureDescription(.captions))
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.busy ? controller.mediaDisclosure : settings.mediaDisclosure(for: .captions, kind: item.kind))
                .font(.footnote).foregroundStyle(.secondary)
            if controller.busy {
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.cancelling ? "Cancelling and cleaning up…" : controller.progress.title).font(.callout)
                    if case .uploading(let value) = controller.progress {
                        ProgressView(value: value)
                        Text(value, format: .percent.precision(.fractionLength(0))).font(.caption).monospacedDigit()
                    } else { ProgressView() }
                    Button("Cancel", role: .cancel) { controller.cancel() }
                        .disabled(controller.cancelling || controller.progress == .saving)
                }
                if !controller.partialText.isEmpty { Text(controller.partialText).textSelection(.enabled) }
            } else {
                Button {
                    if controller.hasEdits { replacing = true }
                    else { generate() }
                } label: {
                    Label(controller.generated == nil ? "Generate caption" : "Regenerate caption", systemImage: "sparkles")
                }.buttonStyle(.borderedProminent)
                    .disabled(!settings.isConfigured(for: .captions, kind: item.kind) || controller.instruction.utf8.count > 2000)
                if !settings.isConfigured(for: .captions, kind: item.kind) { Text("Configure a caption model in Settings first.").font(.footnote).foregroundStyle(.secondary) }
            }
            if controller.generated != nil {
                Text("Caption").font(.headline)
                TextEditor(text: $controller.draft)
                    .frame(minHeight: 120).padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    .disabled(controller.busy)
                HStack {
                    Button("Save edits") { Task { await controller.saveEdits(item: item, library: library) } }
                        .disabled(controller.busy || !controller.hasEdits)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = controller.draft }
                    ShareLink(item: controller.draft) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share caption")
                }
                if let saved = controller.generated {
                    Text("\(saved.effectiveProvider.title) · \(saved.model) · \(saved.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = controller.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let notice = controller.cleanupNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(20)
        .labelStyle(.titleOnly)
        .tint(Color.agoraAccent)
        .onChange(of: scenePhase) { _, phase in if phase == .background { controller.cancel() } }
        .confirmationDialog("Replace your edited draft with a new caption?", isPresented: $replacing, titleVisibility: .visible) {
            Button("Generate new caption") { generate() }
        }
    }
    private func generate() { controller.generate(item: item, file: url, settings: settings, library: library) }
}
