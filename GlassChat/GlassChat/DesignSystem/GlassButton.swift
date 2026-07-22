import SwiftUI

struct GlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        configuration.label
            .fontWeight(.semibold)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(GlassTheme.accent)
            .background {
                if reduceTransparency {
                    shape.fill(Color(.secondarySystemBackground))
                } else if #available(iOS 26.0, *) {
                    Color.clear
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(shape.stroke(GlassTheme.accent.opacity(0.35), lineWidth: 1))
                }
            }
            .modifier(GlassChromeIfAvailable(shape: shape, enabled: !reduceTransparency))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GlassChromeIfAvailable: ViewModifier {
    let shape: RoundedRectangle
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
        }
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glassChat: GlassButtonStyle { GlassButtonStyle() }
}
