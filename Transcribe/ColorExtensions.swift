import SwiftUI
import AppKit

// MARK: - Adaptive Color Helpers

private func adaptiveColor(dark: NSColor, light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let name = appearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua ? dark : light
    }))
}

private func hex(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

// MARK: - Color Palette (Supabase-inspired)

extension Color {
    // Accent colors — green primary
    static let primaryAccent = adaptiveColor(
        dark: hex(0x3ECF8E),
        light: hex(0x2EB57D)
    )
    static let secondaryAccent = adaptiveColor(
        dark: hex(0x34B27B),
        light: hex(0x28966A)
    )
    static let tertiaryAccent = adaptiveColor(
        dark: hex(0x2DA874),
        light: hex(0x249460)
    )

    // Surfaces
    static let surfaceBackground = adaptiveColor(
        dark: hex(0x101012),
        light: hex(0xFFFFFF)
    )
    static let cardBackground = adaptiveColor(
        dark: hex(0x161618),
        light: hex(0xF8F8FA)
    )
    static let elevatedSurface = adaptiveColor(
        dark: hex(0x1E1E20),
        light: hex(0xF0F0F2)
    )
    static let sidebarBackground = adaptiveColor(
        dark: hex(0x131315),
        light: hex(0xFAFAFC)
    )
    static let hoverBackground = adaptiveColor(
        dark: hex(0x3ECF8E, alpha: 0.10),
        light: hex(0x3ECF8E, alpha: 0.08)
    )

    // Text
    static let textPrimary = adaptiveColor(
        dark: hex(0xEDEDED),
        light: hex(0x101015)
    )
    static let textSecondary = adaptiveColor(
        dark: hex(0x8B8B8B),
        light: hex(0x404045)
    )
    static let textTertiary = adaptiveColor(
        dark: hex(0x888888),
        light: hex(0x6E6E75)
    )

    // Chrome
    static let borderLight = adaptiveColor(
        dark: NSColor.white.withAlphaComponent(0.08),
        light: hex(0xE5E5E8)
    )
    static let shadowColor = adaptiveColor(
        dark: NSColor.black.withAlphaComponent(0.30),
        light: NSColor.black.withAlphaComponent(0.04)
    )

    // Gradient anchors
    static let gradientStart = adaptiveColor(
        dark: hex(0x3ECF8E, alpha: 0.15),
        light: hex(0x2EB57D, alpha: 0.10)
    )
    static let gradientEnd = adaptiveColor(
        dark: hex(0x2DA874, alpha: 0.05),
        light: hex(0x249460, alpha: 0.03)
    )
}

// MARK: - Gradients

extension LinearGradient {
    // Green-to-teal accent
    static let accentGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color.primaryAccent,
            Color.tertiaryAccent
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Subtle background wash
    static let primaryGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color.gradientStart,
            Color.gradientEnd
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Card surface gradient
    static let cardGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color.cardBackground,
            Color.elevatedSurface
        ]),
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(Color.cardBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.borderLight, lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCard())
    }
}

// MARK: - Accent Spinner

/// Modern circular spinner using the accent color
struct AccentSpinner: View {
    var size: CGFloat = 20
    var lineWidth: CGFloat = 2.5
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                Color.primaryAccent,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isRotating)
            .onAppear { isRotating = true }
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.material = material
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}