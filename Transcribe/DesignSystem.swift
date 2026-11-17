import SwiftUI
import TranscribeKit

/// Shared measurements. Radii step up with the size of the surface so nested
/// shapes stay visually concentric.
enum Metrics {
    static let controlRadius: CGFloat = 10
    static let cardRadius: CGFloat = 16
    static let tileRadius: CGFloat = 24
    static let panelRadius: CGFloat = 20

    static let gutter: CGFloat = 24
    static let sectionSpacing: CGFloat = 28
}

// MARK: - Backdrop

/// The app's content-layer background: the flat surface colour with a soft
/// wash of the brand green. It is the one place the brand colour appears at
/// scale, and it gives the Liquid Glass controls above it something to
/// refract. Static on purpose — a permanently animating background costs
/// power for decoration.
struct AuroraBackdrop: View {
    /// 0 hides the wash, 1 is the home screen's full strength.
    var intensity: Double = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color.surfaceBackground
            // Increase Contrast asks for plain surfaces
            if contrast != .increased && intensity > 0 {
                GeometryReader { proxy in
                    let size = proxy.size
                    let reach = max(size.width, size.height)
                    ZStack {
                        glow(.brandGreen, strength: 0.20, at: UnitPoint(x: 0.5, y: -0.05), radius: reach * 0.62)
                        glow(Color(red: 0.12, green: 0.72, blue: 0.74), strength: 0.10, at: UnitPoint(x: 0.08, y: 1.02), radius: reach * 0.50)
                        glow(Color(red: 0.30, green: 0.55, blue: 0.95), strength: 0.07, at: UnitPoint(x: 0.96, y: 0.92), radius: reach * 0.46)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, strength: Double, at center: UnitPoint, radius: CGFloat) -> some View {
        // Light surfaces need far less tint before they look dirty
        let scale = colorScheme == .dark ? 1.0 : 0.55
        return RadialGradient(
            colors: [color.opacity(strength * scale * intensity), color.opacity(0)],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

// MARK: - Glass tiles and buttons

/// A large home-screen action rendered as interactive Liquid Glass.
struct FeatureTile: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.primaryAccent.opacity(isHovered ? 0.22 : 0.14))
                        .frame(width: 68, height: 68)
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.primaryAccent)
                        .symbolEffect(.bounce, value: reduceMotion ? false : isHovered)
                }
                VStack(spacing: 3) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .frame(width: 168, height: 168)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Metrics.tileRadius))
        .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }
}

/// The one prominent action on a screen: tinted glass with a label that
/// stays legible on the tint in both appearances.
struct ProminentActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .tint(Color.primaryAccent)
            .foregroundStyle(Color.onAccent)
            .controlSize(.extraLarge)
    }
}

extension View {
    func prominentAction() -> some View {
        modifier(ProminentActionStyle())
    }

    /// A secondary action on glass.
    func glassAction() -> some View {
        buttonStyle(.glass).controlSize(.large)
    }
}

/// The label of a toolbar control that picks a value (language, model):
/// icon, current value and a chevron, so every chooser reads the same and
/// differs from the action buttons next to it. The padding keeps the text
/// clear of the glass capsule's edge.
struct ToolbarChooserLabel<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 7) {
            icon
            // Set explicitly: the toolbar draws a button's title heavier
            // than a menu's, and the two choosers sit side by side
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
    }
}

/// Back button for a screen's toolbar (the system gives it glass).
struct BackToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(localized("back"), systemImage: "chevron.left")
        }
        .help(localized("back"))
        .keyboardShortcut("[", modifiers: .command)
    }
}

// MARK: - Meters

/// A rolling history of input levels, drawn as centred bars — the newest on
/// the right. Shows at a glance that sound is arriving and how loud it has
/// been, which a single instantaneous meter cannot.
struct WaveformMeter: View {
    /// Levels in 0…1, oldest first.
    let levels: [Float]
    var barCount: Int = 56
    var color: Color = .primaryAccent
    var isActive: Bool = true

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3
            let barWidth = max(2, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let recent = levels.suffix(barCount)
            let offset = barCount - recent.count
            for (index, level) in recent.enumerated() {
                let position = index + offset
                let clamped = CGFloat(max(0, min(1, level)))
                // A floor keeps silent bars visible as a baseline
                let height = max(3, clamped * size.height)
                let rect = CGRect(
                    x: CGFloat(position) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                // Older bars fade so the eye lands on "now"
                let age = Double(position) / Double(max(barCount - 1, 1))
                let opacity = (isActive ? 0.25 : 0.12) + (isActive ? 0.75 : 0.2) * age
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color.opacity(opacity))
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel(localized("audio_level"))
        .accessibilityValue("\(Int((levels.last ?? 0) * 100)) %")
    }
}

/// Keeps the last few seconds of level readings for `WaveformMeter`.
struct LevelHistory {
    private(set) var levels: [Float]
    private let capacity: Int

    init(capacity: Int = 56) {
        self.capacity = capacity
        self.levels = Array(repeating: 0, count: capacity)
    }

    mutating func append(_ level: Float) {
        levels.append(level)
        if levels.count > capacity {
            levels.removeFirst(levels.count - capacity)
        }
    }

    mutating func reset() {
        levels = Array(repeating: 0, count: capacity)
    }
}

// MARK: - Small pieces

/// A compact status marker: a dot (optionally pulsing) and a label.
struct StatusBadge: View {
    let text: String
    var color: Color = .primaryAccent
    var isPulsing = false

    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(dimmed ? 0.35 : 1)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
        }
        .onAppear { updatePulse() }
        .onChange(of: isPulsing) { _, _ in updatePulse() }
        .accessibilityElement(children: .combine)
    }

    private func updatePulse() {
        guard isPulsing, !reduceMotion else {
            withAnimation(.default) { dimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

/// `mm:ss.t` for recording clocks.
func formatClock(_ time: TimeInterval, tenths: Bool = true) -> String {
    let safe = max(0, time.isFinite ? time : 0)
    let total = Int(safe)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    let head = hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%02d:%02d", minutes, seconds)
    guard tenths else { return head }
    return head + String(format: ".%d", Int((safe - Double(total)) * 10))
}
