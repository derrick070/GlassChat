import SwiftUI

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = GlassTheme.surfaceRadius

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            content
                .background(Color(.secondarySystemBackground), in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                materialFallback(content, shape: shape)
            }
            #else
            materialFallback(content, shape: shape)
            #endif
        }
    }

    @ViewBuilder
    private func materialFallback(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5))
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = GlassTheme.surfaceRadius) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

struct AtmosphereBackground: View {
    @Environment(\.colorScheme) private var colorScheme

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
                    colors: meshColors
                )
            } else {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }

    private var meshColors: [Color] {
        if colorScheme == .dark {
            [
                Color(red: 0.08, green: 0.14, blue: 0.16),
                Color(red: 0.10, green: 0.18, blue: 0.20),
                Color(red: 0.12, green: 0.14, blue: 0.20),
                Color(red: 0.06, green: 0.12, blue: 0.14),
                Color(red: 0.11, green: 0.15, blue: 0.18),
                Color(red: 0.09, green: 0.13, blue: 0.19),
                Color(red: 0.07, green: 0.14, blue: 0.15),
                Color(red: 0.10, green: 0.12, blue: 0.16),
                Color(red: 0.08, green: 0.13, blue: 0.17)
            ]
        } else {
            [
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
        }
    }

    private var gradientColors: [Color] {
        if colorScheme == .dark {
            [
                Color(red: 0.08, green: 0.14, blue: 0.16),
                Color(red: 0.10, green: 0.16, blue: 0.20),
                Color(red: 0.09, green: 0.12, blue: 0.18)
            ]
        } else {
            [
                Color(red: 0.90, green: 0.95, blue: 0.96),
                Color(red: 0.82, green: 0.90, blue: 0.93),
                Color(red: 0.88, green: 0.91, blue: 0.95)
            ]
        }
    }
}
