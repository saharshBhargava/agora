import SwiftUI

struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable { case paragraph, heading(Int), quote, list(String), code(String), table }
    let id: Int
    let kind: Kind
    let text: String
    static func parse(_ source: String) -> [Self] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [Self] = [], paragraph: [String] = []
        var index = 0
        func append(_ kind: Kind, _ text: String) { blocks.append(.init(id: blocks.count, kind: kind, text: text)) }
        func flush() { if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] } }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); let marker = String(trimmed.prefix(3)), language = String(trimmed.dropFirst(3))
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(marker) { code.append(lines[index]); index += 1 }
                append(.code(language), code.joined(separator: "\n"))
            } else if index + 1 < lines.count, line.contains("|"), lines[index + 1].range(of: #"^\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil {
                flush(); var rows = [line]; index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].isEmpty { rows.append(lines[index]); index += 1 }
                append(.table, rows.joined(separator: "\n")); continue
            } else if trimmed.isEmpty { flush() }
            else if let range = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush(); append(.heading(trimmed.distance(from: trimmed.startIndex, to: range.upperBound) - 1), String(trimmed[range.upperBound...]))
            } else if trimmed.hasPrefix("> ") { flush(); append(.quote, String(trimmed.dropFirst(2))) }
            else if let range = trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush(); let prefix = String(trimmed[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
                append(.list(prefix.count == 1 ? "•" : prefix), String(trimmed[range.upperBound...]))
            } else { paragraph.append(line) }
            index += 1
        }
        flush(); return blocks
    }
}

struct ChatMarkdown: View, Equatable {
    let text: String
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph: inline(block.text).lineSpacing(4)
                case .heading(let level): inline(block.text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).accessibilityAddTraits(.isHeader).padding(.top, 4)
                case .quote:
                    HStack(alignment: .top, spacing: 12) { RoundedRectangle(cornerRadius: 2).fill(.teal.opacity(0.5)).frame(width: 3); inline(block.text).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case .list(let marker): HStack(alignment: .top, spacing: 10) { Text(marker).foregroundStyle(.secondary); inline(block.text).frame(maxWidth: .infinity, alignment: .leading) }
                case .code(let language):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(language.isEmpty ? "Code" : language).font(.caption.weight(.medium)); Spacer(); ChatCopyButton(text: block.text, label: "Copy code") }.padding(.horizontal, 12)
                        Divider()
                        ScrollView(.horizontal) { Text(block.text).font(.callout.monospaced()).textSelection(.enabled).padding(12) }
                    }.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                case .table:
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            ForEach(Array(block.text.components(separatedBy: "\n").enumerated()), id: \.offset) { row, line in
                                GridRow {
                                    ForEach(Array(cells(line).enumerated()), id: \.offset) { _, cell in inline(cell).font(row == 0 ? .subheadline.bold() : .subheadline).frame(minWidth: 100, alignment: .leading) }
                                }
                                if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(14)
                    }.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    private func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct ChatCopyButton: View {
    let text: String
    var label = "Copy message"
    @State private var copied = false
    var body: some View {
        Button { UIPasteboard.general.string = text; copied = true } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption).frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(copied ? "Copied" : label)
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); copied = false } }
    }
}

struct ChatMessageView: View {
    @ObservedObject var message: ChatMessage
    let approve: (Bool) -> Void
    let retry: (String) -> Void
    let openBrowser: () -> Void
    @State private var preview: ChatAttachment?
    var body: some View {
        Group {
            if let tool = message.tool { toolView(tool) }
            else if let approval = message.approval { approvalView(approval) }
            else if message.role == "notice" { notice }
            else { bubble }
        }
        .sheet(item: $preview) { attachment in NavigationStack { ChatAttachmentPreview(attachment: attachment).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } } } }
    }
    private var bubble: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 8) {
                if message.role != "user" {
                    Label("Agora", systemImage: "sparkle").font(.subheadline.weight(.semibold)).foregroundStyle(.teal).padding(.bottom, 2)
                }
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        Button { preview = attachment } label: {
                            if let image = attachment.image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 12)) }
                            else { Label(attachment.name, systemImage: "doc.text").font(.subheadline).lineLimit(2).padding(10) }
                        }.accessibilityLabel("Preview \(attachment.name)")
                    }
                }
                if message.role == "user" { Text(message.text).textSelection(.enabled) }
                else { ChatMarkdown(text: message.text).equatable() }
                if message.streaming { Text("Writing…").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Agora is writing") }
                else if message.role != "user" { ChatCopyButton(text: message.text) }
            }
            .padding(message.role == "user" ? 14 : 0)
            .background(message.role == "user" ? Color(.secondarySystemBackground) : .clear, in: RoundedRectangle(cornerRadius: 20))
            .contextMenu { Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
            if message.role != "user" { Spacer(minLength: 0) }
        }
    }
    private func toolView(_ tool: ChatToolActivity) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.input.isEmpty { Text(tool.input) }
                if !tool.result.isEmpty { Text(tool.result).foregroundStyle(.secondary) }
            }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                if tool.status == .running { ProgressView().controlSize(.small) }
                else { Image(systemName: tool.status == .complete ? "checkmark.circle" : tool.status == .failed ? "exclamationmark.circle" : "stop.circle").foregroundStyle(tool.status == .failed ? .orange : .secondary) }
                VStack(alignment: .leading, spacing: 3) { Text(tool.name).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary); Text(tool.status.rawValue).font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }.padding(12).background(Color(.secondarySystemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
    private func approvalView(_ record: ChatApprovalRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(record.status.rawValue, systemImage: record.status == .pending ? "hand.raised" : record.status == .approved ? "checkmark.seal" : "xmark.seal").font(.caption.bold()).foregroundStyle(record.status == .pending ? .orange : record.status == .approved ? .teal : .secondary)
            Text(record.title).font(.headline)
            Text(record.detail).font(.callout).textSelection(.enabled)
            if record.status == .pending {
                ViewThatFits {
                    HStack { approvalButtons }
                    VStack(alignment: .leading) { approvalButtons }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(record.status == .pending ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.2)))
    }
    @ViewBuilder private var approvalButtons: some View {
        Button("Approve") { approve(true) }.buttonStyle(.borderedProminent).controlSize(.large)
        Button("Cancel", role: .cancel) { approve(false) }.buttonStyle(.bordered).controlSize(.large)
        Button("Open Browser", action: openBrowser).font(.callout).frame(minHeight: 44)
    }
    private var notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs attention", systemImage: "exclamationmark.circle").font(.subheadline.bold()).foregroundStyle(.orange)
            Text(ChatDisplayText.notice(message.text)).font(.callout).textSelection(.enabled)
            if let text = message.retryText { Button("Retry", systemImage: "arrow.clockwise") { retry(text) }.frame(minHeight: 44) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}


enum ChatDisplayText {
    static func notice(_ value: String) -> String {
        if let prefix = value.range(of: #"^[a-z][a-z_0-9]+: "#, options: .regularExpression) { return String(value[prefix.upperBound...]) }
        switch value {
        case "incomplete_model_response": return "The connection ended before the response completed. Please retry."
        case "no_browser": return "Open a website in the shared browser to continue."
        case "timeout": return "This took longer than expected. Check your connection and try again."
        case "tool_budget_exhausted": return "This task reached its action limit. Review the progress and continue with a smaller request."
        default: return value
        }
    }
}
