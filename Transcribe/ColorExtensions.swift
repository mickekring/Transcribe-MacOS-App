import SwiftUI
import TranscribeKit
import AppKit

// MARK: - Adaptive Color Helpers

/// A colour that follows the window's appearance, including the Increase
/// Contrast variants (which default to the regular colour when not given).
private func adaptiveColor(
    dark: NSColor,
    light: NSColor,
    darkHighContrast: NSColor? = nil,
    lightHighContrast: NSColor? = nil
) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let match = appearance.bestMatch(from: [
            .darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
        ])
        switch match {
        case .accessibilityHighContrastDarkAqua: return darkHighContrast ?? dark
        case .accessibilityHighContrastAqua: return lightHighContrast ?? light
        case .darkAqua: return dark
        default: return light
        }
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

// MARK: - Color Palette

extension Color {
    // Accent — the brand green. The light-mode value is darker so that it
    // reads as text and icons on white (4.9:1) and carries white labels
    // when used as a fill; the bright green only works on dark surfaces.
    static let primaryAccent = adaptiveColor(
        dark: hex(0x3ECF8E),
        light: hex(0x17804F),
        darkHighContrast: hex(0x6FF0B4),
        lightHighContrast: hex(0x0B5C36)
    )
    static let secondaryAccent = adaptiveColor(
        dark: hex(0x34B27B),
        light: hex(0x1F8C5B)
    )
    static let tertiaryAccent = adaptiveColor(
        dark: hex(0x2DA874),
        light: hex(0x27A06C)
    )
    /// The brand green at full brightness in both appearances, for glows,
    /// meters and other decoration that never carries text.
    static let brandGreen = Color(nsColor: hex(0x3ECF8E))
    /// Text and icons placed on a `primaryAccent` fill: dark on the bright
    /// dark-mode green (white would be 2:1), white on the light-mode green.
    static let onAccent = adaptiveColor(
        dark: hex(0x04241A),
        light: hex(0xFFFFFF)
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
        light: hex(0x17804F, alpha: 0.08)
    )

    // Text. Secondary and tertiary both clear 4.5:1 on their surface;
    // tertiary is for captions and metadata.
    static let textPrimary = adaptiveColor(
        dark: hex(0xEDEDED),
        light: hex(0x101015),
        darkHighContrast: hex(0xFFFFFF),
        lightHighContrast: hex(0x000000)
    )
    static let textSecondary = adaptiveColor(
        dark: hex(0xA0A0A6),
        light: hex(0x404045),
        darkHighContrast: hex(0xD0D0D4),
        lightHighContrast: hex(0x202024)
    )
    static let textTertiary = adaptiveColor(
        dark: hex(0x7E7E84),
        light: hex(0x6A6A71),
        darkHighContrast: hex(0xB4B4B9),
        lightHighContrast: hex(0x3A3A40)
    )

    // Chrome
    static let borderLight = adaptiveColor(
        dark: NSColor.white.withAlphaComponent(0.08),
        light: hex(0xE5E5E8),
        darkHighContrast: NSColor.white.withAlphaComponent(0.35),
        lightHighContrast: hex(0x8A8A90)
    )
    static let shadowColor = adaptiveColor(
        dark: NSColor.black.withAlphaComponent(0.30),
        light: NSColor.black.withAlphaComponent(0.04)
    )
    /// Recording / destructive state.
    static let recordingRed = adaptiveColor(
        dark: hex(0xFF5A52),
        light: hex(0xD92D20)
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

// MARK: - Content-layer card

/// A solid, hairline-bordered surface for content (transcripts, settings
/// groups, status cards). Content surfaces stay opaque for legibility;
/// Liquid Glass is reserved for controls that float above them.
struct ContentCard: ViewModifier {
    var cornerRadius: CGFloat = Metrics.cardRadius

    func body(content: Content) -> some View {
        content
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.borderLight, lineWidth: 0.5)
            )
    }
}

extension View {
    func contentCard(cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        modifier(ContentCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Accent Spinner

/// Modern circular spinner using the accent color
struct AccentSpinner: View {
    var size: CGFloat = 20
    var lineWidth: CGFloat = 2.5
    @State private var isRotating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // A steady partial ring still reads as "busy" without spinning
            ring.opacity(0.9)
        } else {
            ring
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isRotating)
                .onAppear { isRotating = true }
        }
    }

    private var ring: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                Color.primaryAccent,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
