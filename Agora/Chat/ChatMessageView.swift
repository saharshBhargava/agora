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
                case .paragraph: inline(block.text).font(.system(size: 16)).foregroundStyle(Color.bodyInk).lineSpacing(4)
                case .heading(let level): inline(block.text).font(.display(level == 1 ? 22 : level == 2 ? 20 : 17)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader).padding(.top, 4)
                case .quote:
                    HStack(alignment: .top, spacing: 12) { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.lineStrong).frame(width: 3); inline(block.text).font(.system(size: 16)).foregroundStyle(Color.muted) }.fixedSize(horizontal: false, vertical: true)
                case .list(let marker): HStack(alignment: .top, spacing: 10) { Text(marker).font(.system(size: 16)).foregroundStyle(Color.muted); inline(block.text).font(.system(size: 16)).foregroundStyle(Color.bodyInk).frame(maxWidth: .infinity, alignment: .leading) }
                case .code(let language):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(language.isEmpty ? "Code" : language).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.muted); Spacer(); ChatCopyButton(text: block.text, label: "Copy code") }.padding(.horizontal, 12)
                        Color.line.frame(height: 1)
                        ScrollView(.horizontal) { Text(block.text).font(.receipt(14)).foregroundStyle(Color.ink).textSelection(.enabled).padding(12) }
                    }.background(Color.paper, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)).overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.line))
                case .table:
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                            ForEach(Array(block.text.components(separatedBy: "\n").enumerated()), id: \.offset) { row, line in
                                GridRow {
                                    ForEach(Array(cells(line).enumerated()), id: \.offset) { _, cell in inline(cell).font(.system(size: 15, weight: row == 0 ? .bold : .regular)).foregroundStyle(row == 0 ? Color.ink : Color.bodyInk).frame(minWidth: 100, alignment: .leading) }
                                }
                                if row == 0 { Color.line.frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(14)
                    }.background(Color.paper, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)).overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.line))
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
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(Color.muted).accessibilityLabel(copied ? "Copied" : label)
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
        .tint(Color.ink)
        .sheet(item: $preview) { attachment in NavigationStack { ChatAttachmentPreview(attachment: attachment).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } } }.tint(Color.ink) }
    }
    private var isUser: Bool { message.role == "user" }
    private var bubble: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 8) {
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        Button { preview = attachment } label: {
                            if let image = attachment.image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)) }
                            else {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).frame(width: 36, height: 36)
                                        .background(tileColor(id: attachment.id.uuidString), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    Text(attachment.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(2)
                                }
                            }
                        }.accessibilityLabel("Preview \(attachment.name)")
                    }
                }
                if isUser { Text(message.text).font(.system(size: 16)).foregroundStyle(Color.ink).textSelection(.enabled) }
                else { ChatMarkdown(text: message.text).equatable() }
                if message.streaming {
                    HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Writing…").font(.system(size: 13)).foregroundStyle(Color.muted) }
                        .accessibilityElement(children: .ignore).accessibilityLabel("Dibs is writing")
                } else if !isUser {
                    Color.line.frame(height: 1)
                    ChatCopyButton(text: message.text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, !isUser && !message.streaming ? 0 : 14)
            .background(isUser ? Color.meSoft : Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(isUser ? Color.meBlue.opacity(0.22) : Color.line))
            .contextMenu { Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
            if !isUser { Spacer(minLength: 0) }
        }
    }
    private func toolView(_ tool: ChatToolActivity) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.input.isEmpty { Text(tool.input).foregroundStyle(Color.bodyInk) }
                if !tool.result.isEmpty { Text(tool.result).foregroundStyle(Color.muted) }
            }.font(.system(size: 15)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    tileColor(id: tool.name)
                    if tool.status == .running { ProgressView().controlSize(.small) }
                    else { Image(systemName: tool.status == .complete ? "checkmark" : tool.status == .failed ? "exclamationmark" : "stop.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(tool.status == .failed ? Color.danger : Color.ink) }
                }.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) { Text(tool.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink); Text(tool.status.rawValue).font(.system(size: 13)).foregroundStyle(Color.muted) }
            }
        }.tint(Color.ink).dibsCard(radius: 14, padding: 12)
    }
    private func approvalView(_ record: ChatApprovalRecord) -> some View {
        let pending = record.status == .pending
        return VStack(alignment: .leading, spacing: 12) {
            Label(record.status.rawValue, systemImage: pending ? "hand.raised" : record.status == .approved ? "checkmark.seal" : "xmark.seal")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(pending ? Color.white : record.status == .approved ? Color.ink : Color.muted)
                .padding(.horizontal, 12).frame(minHeight: 30)
                .background(pending ? Color.ink : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(pending ? Color.ink : Color.lineStrong))
            Text(record.title).font(.display(20)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            Text(record.detail).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk).textSelection(.enabled)
            if pending {
                VStack(spacing: Metrics.space1) { approvalButtons }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)).overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(pending ? Color.ink : Color.line, lineWidth: pending ? 1.5 : 1))
    }
    @ViewBuilder private var approvalButtons: some View {
        Button("Approve") { approve(true) }.buttonStyle(.dibs)
        Button("Cancel", role: .cancel) { approve(false) }.buttonStyle(.dibs(.secondary))
        Button("Open Browser", action: openBrowser).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).frame(maxWidth: .infinity, minHeight: 44)
    }
    private var notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs attention", systemImage: "exclamationmark.circle").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.danger)
            Text(ChatDisplayText.notice(message.text)).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk).textSelection(.enabled)
            if let text = message.retryText { Button { retry(text) } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.dibs(.secondary, fontSize: 15)) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
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
