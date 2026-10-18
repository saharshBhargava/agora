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
        VStack(alignment: .leading, spacing: Metrics.space2) {
            header
            optionsCard
            if controller.busy {
                progressCard
                if !controller.partialText.isEmpty {
                    Text(controller.partialText).font(.system(size: 16)).lineSpacing(3).foregroundStyle(Color.bodyInk).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).dibsCard()
                }
            } else {
                Button {
                    if controller.hasEdits { replacing = true }
                    else { generate() }
                } label: {
                    Label(controller.generated == nil ? "Generate caption" : "Regenerate caption", systemImage: "sparkles")
                }.buttonStyle(.dibs)
                    .disabled(!settings.isConfigured(for: .captions, kind: item.kind) || controller.instruction.utf8.count > 2000)
                if !settings.isConfigured(for: .captions, kind: item.kind) {
                    Text("Configure a caption model in Settings first.")
                        .font(.system(size: 14)).foregroundStyle(Color.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            if controller.generated != nil { resultCard }
            if let message = controller.message { Text(message).font(.system(size: 13)).foregroundStyle(Color.muted) }
            if let notice = controller.cleanupNotice { Text(notice).font(.system(size: 13)).foregroundStyle(Color.muted) }
        }
        .tint(Color.ink)
        .padding(.horizontal, 20).padding(.vertical, Metrics.space2)
        .onChange(of: scenePhase) { _, phase in if phase == .background { controller.cancel() } }
        .confirmationDialog("Replace your edited draft with a new caption?", isPresented: $replacing, titleVisibility: .visible) {
            Button("Generate new caption") { generate() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Generate caption", systemImage: "sparkles").font(.display(28)).tracking(-0.5).foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(controller.busy ? controller.modelDescription : settings.featureDescription(.captions))
                .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
            MenuFieldRow(title: "Style", value: controller.style.title) {
                Picker("Style", selection: $controller.style) {
                    ForEach(CaptionStyle.allCases) { style in Text(style.title).tag(style) }
                }
            }.disabled(controller.busy)
            TextField("Optional instructions, e.g. focus on the clothing", text: $controller.instruction, axis: .vertical)
                .font(.system(size: 16)).foregroundStyle(Color.ink)
                .lineLimit(2...4).padding(.vertical, 14).dibsInput().disabled(controller.busy)
            Text(controller.busy ? controller.mediaDisclosure : settings.mediaDisclosure(for: .captions, kind: item.kind))
                .font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.cancelling ? "Cancelling and cleaning up…" : controller.progress.title)
                .font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
            if case .uploading(let value) = controller.progress {
                ProgressView(value: value).tint(Color.ink)
                Text(value, format: .percent.precision(.fractionLength(0))).font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
            } else { ProgressView().tint(Color.ink) }
            Button("Cancel", role: .cancel) { controller.cancel() }
                .buttonStyle(.dibs(.secondary))
                .disabled(controller.cancelling || controller.progress == .saving)
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Caption").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
            TextEditor(text: $controller.draft)
                .font(.system(size: 16)).foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120).padding(8)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.line))
                .disabled(controller.busy)
            if let saved = controller.generated {
                Text("\(saved.effectiveProvider.title) · \(saved.model) · \(saved.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13)).foregroundStyle(Color.muted)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.line))
            }
            Button("Save edits") { Task { await controller.saveEdits(item: item, library: library) } }
                .buttonStyle(.dibs)
                .disabled(controller.busy || !controller.hasEdits)
            HStack(spacing: Metrics.space1) {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = controller.draft }
                    .buttonStyle(.dibs(.secondary))
                ShareLink(item: controller.draft) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.dibs(.secondary))
                    .accessibilityLabel("Share caption")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private func generate() { controller.generate(item: item, file: url, settings: settings, library: library) }
}
