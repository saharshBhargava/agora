import SwiftUI

/// Avatar sizes (web .avatar-xs / -sm / md / -lg).
enum AvatarSize {
    case xs, sm, md, lg

    var diameter: CGFloat {
        switch self { case .xs: 24; case .sm: 32; case .md: 36; case .lg: 40 }
    }
    var fontSize: CGFloat {
        switch self { case .xs: 11; case .sm: 13; case .md: 15; case .lg: 16 }
    }
    /// How far each avatar tucks under the previous one in a stack.
    var overlap: CGFloat {
        switch self { case .xs: 6; case .sm: 8; case .md, .lg: 10 }
    }
}

/// One round initial in the person's color (`ringColor`). Dashed means "joining": white with a blue dashed ring.
struct Avatar: View {
    let person: Person
    let people: [Person]
    let me: String
    var size: AvatarSize = .md
    var dashed = false
    /// The ring that separates stacked avatars; match the surface behind them.
    var ring: Color = .card

    var body: some View {
        let color = ringColor(people: people, id: person.id, me: me)
        Text(person.initial)
            .font(.system(size: size.fontSize, weight: .bold))
            .foregroundStyle(dashed ? Color.meBlue : Color.white)
            .frame(width: size.diameter, height: size.diameter)
            .background(Circle().fill(dashed ? Color.card : color))
            .overlay {
                if dashed {
                    Circle().strokeBorder(Color.meBlue, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                } else if size != .lg {
                    Circle().strokeBorder(ring, lineWidth: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Overlapping initials. `label` names the group for VoiceOver.
struct AvatarStack: View {
    let list: [Person]
    let people: [Person]
    let me: String
    var size: AvatarSize = .md
    var dashedId: String?
    var ring: Color = .card
    var label: String?

    var body: some View {
        HStack(spacing: -size.overlap) {
            ForEach(list) { p in
                Avatar(person: p, people: people, me: me, size: size, dashed: p.id == dashedId, ring: ring)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? RunText.listNames(list.map(\.name)))
    }
}

#if DEBUG
#Preview("Avatars") {
    let run = PreviewData.run
    VStack(spacing: 16) {
        AvatarStack(list: run.people, people: run.people, me: PreviewData.priyaId)
        AvatarStack(list: run.people, people: run.people, me: run.shopperId, size: .sm)
        Avatar(person: Person(id: "lee", name: "Lee", initial: "L", isShopper: false), people: run.people, me: "lee", dashed: true)
    }
    .padding()
    .background(Color.paper)
}
#endif
