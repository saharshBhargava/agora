import SwiftUI

/// "$40.00 held · approval 123456" in a soft blue pill (web HeldBadge).
struct HeldBadge: View {
    let cents: Int
    var approvalCode: String?

    static func text(cents: Int, approvalCode: String?) -> String {
        let code = approvalCode.flatMap { $0.isEmpty ? nil : " · approval \($0)" } ?? ""
        return "\(Money.format(cents)) held\(code)"
    }

    var body: some View {
        Text(Self.text(cents: cents, approvalCode: approvalCode))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.meBlue)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(Capsule().fill(Color.meSoft))
    }
}

#if DEBUG
#Preview("Held badge") {
    VStack(alignment: .leading, spacing: 12) {
        HeldBadge(cents: 4000, approvalCode: "831002")
        HeldBadge(cents: 6000)
    }
    .padding()
    .background(Color.paper)
}
#endif
