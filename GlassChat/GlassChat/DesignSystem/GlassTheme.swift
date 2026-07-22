import SwiftUI

enum GlassTheme {
    static let spacing: CGFloat = 12
    static let bubbleRadius: CGFloat = 18
    static let surfaceRadius: CGFloat = 24
    static let accent = Color(red: 0.18, green: 0.62, blue: 0.62)
    static let outgoingBubble = Color(red: 0.18, green: 0.62, blue: 0.62).opacity(0.88)
    static let incomingBubble = Color.primary.opacity(0.08)
}
