import SwiftUI

// Design tokens. Colors are exact (web/app/globals.css and web/lib/share.ts).

extension Color {
    /// `Color(hex: 0x2B59E8)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static let paper = Color(hex: 0xF5F3EF)
    static let card = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x111111)
    static let muted = Color(hex: 0x5E5B55)
    static let line = Color(hex: 0xE3DFD8)
    static let lineStrong = Color(hex: 0xC9C5BE)
    static let meBlue = Color(hex: 0x2B59E8)
    static let meSoft = Color(hex: 0xEEF2FD)
    static let secondPerson = Color(hex: 0xD9480F)
    static let shopperTeal = Color(hex: 0x0F7B6C)
    static let tealSoft = Color(hex: 0xD3EDE8)
    static let liveRed = Color(hex: 0xE03131)
    static let danger = Color(hex: 0xB42318)
    static let dangerSoft = Color(hex: 0xFDECEC)
    static let cameraDark = Color(hex: 0x1C1A17)
}

enum Palette {
    /// "Me" (a claimer) is always blue.
    static let meHex: UInt32 = 0x2B59E8
    /// The shopper is always teal.
    static let shopperHex: UInt32 = 0x0F7B6C
    /// Other claimers in join order: orange first. Every color keeps white initials at 4.5:1 or better.
    static let otherHex: [UInt32] = [0xD9480F, 0x7048E8, 0xC2255C, 0x2F7A1F, 0x8A5A00]
    /// The whole claimer palette, blue first: used when the viewer is the shopper.
    static let ringHex: [UInt32] = [meHex] + otherHex

    /// Soft placeholder tints for product tiles (web/lib/tile.ts).
    static let tileHex: [UInt32] = [0xF2E3B5, 0xD8E2FA, 0xECEAE6, 0xF6D9CC, 0xD3EDE8, 0xE5DDF7]
}

/// A claimer's color by join order among the other claimers. `isMe` is always blue; otherwise
/// orange, then purple, pink, green, brown, repeating.
func personColor(index: Int, isMe: Bool) -> Color {
    if isMe { return Color(hex: Palette.meHex) }
    let p = Palette.otherHex
    return Color(hex: p[((index % p.count) + p.count) % p.count])
}

/// The per-person color exactly as the web's `ringColor`: the shopper is teal; "me" (a claimer) is
/// blue; other claimers take orange then the palette in join order. When the viewer is the shopper,
/// the first claimer takes blue so every claimer keeps one color across phones.
func ringColorHex(people: [Person], id: String, me: String) -> UInt32 {
    if people.first(where: { $0.id == id })?.isShopper == true { return Palette.shopperHex }
    let meIsClaimer = people.contains { $0.id == me && !$0.isShopper }
    if id == me && meIsClaimer { return Palette.meHex }
    let claimers = people.filter { !$0.isShopper && !(meIsClaimer && $0.id == me) }
    let palette = meIsClaimer ? Palette.otherHex : Palette.ringHex
    let i = max(0, claimers.firstIndex { $0.id == id } ?? 0)
    return palette[i % palette.count]
}

func ringColor(people: [Person], id: String, me: String) -> Color {
    Color(hex: ringColorHex(people: people, id: id, me: me))
}

/// A stable soft tint for a chip tile, same hash as web/lib/tile.ts.
func tileColor(id: String) -> Color {
    var h: UInt32 = 0
    for unit in id.utf16 { h = h &* 31 &+ UInt32(unit) }
    return Color(hex: Palette.tileHex[Int(h % UInt32(Palette.tileHex.count))])
}

extension Font {
    /// Display and money: system rounded, heavy.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    /// Receipt lines: monospaced.
    static func receipt(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
}

enum Metrics {
    static let radius: CGFloat = 18
    static let radiusLarge: CGFloat = 24
    static let radiusSmall: CGFloat = 12
    static let tap: CGFloat = 44
    static let buttonHeight: CGFloat = 56
    static let space1: CGFloat = 8
    static let space2: CGFloat = 16
    static let space3: CGFloat = 24
    static let space4: CGFloat = 32
}
