import SwiftUI

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = GlassTheme.surfaceRadius

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = GlassTheme.surfaceRadius) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

struct AtmosphereBackground: View {
    var body: some View {
        ZStack {
            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        .init(0, 0), .init(0.5, 0), .init(1, 0),
                        .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                        .init(0, 1), .init(0.5, 1), .init(1, 1)
                    ],
                    colors: [
                        Color(red: 0.90, green: 0.95, blue: 0.96),
                        Color(red: 0.82, green: 0.92, blue: 0.93),
                        Color(red: 0.88, green: 0.90, blue: 0.95),
                        Color(red: 0.78, green: 0.88, blue: 0.90),
                        Color(red: 0.92, green: 0.94, blue: 0.96),
                        Color(red: 0.80, green: 0.86, blue: 0.92),
                        Color(red: 0.86, green: 0.93, blue: 0.91),
                        Color(red: 0.90, green: 0.91, blue: 0.94),
                        Color(red: 0.84, green: 0.90, blue: 0.93)
                    ]
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.90, green: 0.95, blue: 0.96),
                        Color(red: 0.82, green: 0.90, blue: 0.93),
                        Color(red: 0.88, green: 0.91, blue: 0.95)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}
