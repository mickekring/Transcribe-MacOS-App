import SwiftUI
import UIKit
import TranscribeKit

// The Mac app's Supabase-inspired palette (Transcribe/ColorExtensions.swift),
// ported to UIKit dynamic providers so the same names work in iOS views.
// Keep the hex values in sync with the Mac file.

private func adaptiveColor(dark: UIColor, light: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    })
}

private func hex(_ hex: UInt32, alpha: CGFloat = 1.0) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

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
        dark: UIColor.white.withAlphaComponent(0.08),
        light: hex(0xE5E5E8)
    )
}

extension LinearGradient {
    static let accentGradient = LinearGradient(
        gradient: Gradient(colors: [
            Color.primaryAccent,
            Color.tertiaryAccent
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Accent Spinner (same as the Mac app's)

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

// MARK: - Theme selection (matches the Mac's appColorScheme key)

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    var label: String {
        switch self {
        case .dark: return localized("ios_theme_dark")
        case .light: return localized("ios_theme_light")
        case .system: return localized("ios_theme_system")
        }
    }
}
