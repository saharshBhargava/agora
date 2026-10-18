import SwiftUI

/// One toast at a time (web UndoToast and .toast). With `undo`, the Undo button counts down; without it,
/// it is a plain notice such as a server refusal. The owner replaces it by setting a new `Toast`.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    /// When it was raised; the countdown runs from here even if the view is rebuilt (a pushed screen and back).
    let created = Date()
    let label: String
    var seconds: Double = Double(ClaimLogic.undoSeconds)
    var undo: (@MainActor () -> Void)?

    static func notice(_ label: String) -> Toast { Toast(label: label, seconds: ClaimLogic.noticeSeconds) }
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct UndoToast: View {
    let toast: Toast
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: Metrics.space2) {
            Text(toast.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo = toast.undo {
                TimelineView(.periodic(from: toast.created, by: 0.25)) { context in
                    let left = max(1, Int((toast.seconds - context.date.timeIntervalSince(toast.created)).rounded(.up)))
                    Button {
                        undo()
                        onDismiss()
                    } label: {
                        Text("Undo · \(left)s")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(minHeight: Metrics.tap)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Undo")
                }
            }
        }
        .padding(.horizontal, Metrics.space2)
        .frame(minHeight: 48)
        .background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if toast.undo != nil {
                CountdownBar(seconds: toast.seconds, created: toast.created)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .task(id: toast.id) {
            let left = toast.seconds - Date().timeIntervalSince(toast.created)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            if !Task.isCancelled { onDismiss() }
        }
    }
}

/// The thin bar under an undo toast that empties over its window.
private struct CountdownBar: View {
    let seconds: Double
    let created: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let left = seconds > 0 ? max(0, 1 - context.date.timeIntervalSince(created) / seconds) : 0
            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: geo.size.width * left, height: 2)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Toasts") {
    VStack(spacing: 16) {
        UndoToast(toast: Toast(label: "Claimed Kirkland Eggs 24 ct", seconds: 30, undo: {}))
        UndoToast(toast: .notice("Over cap"))
    }
    .padding()
    .background(Color.paper)
}
#endif
