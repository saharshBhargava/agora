import SwiftUI

/// Drop target over the camera, shown while a cart row is lifted (web RemoveZone). The whole camera
/// area accepts the drop; this card says so.
struct RemoveZone: View {
    /// The lifted row is over the camera.
    var isOver: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 20, weight: .semibold))
            Text("Drop here to remove from cart")
                .font(.system(size: 16, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(Color.liveRed.opacity(isOver ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        )
        .scaleEffect(isOver ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isOver)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Remove zone") {
    VStack(spacing: 16) {
        RemoveZone(isOver: false)
        RemoveZone(isOver: true)
    }
    .padding()
    .background(Color.cameraDark)
}
#endif
