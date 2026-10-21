import AppKit
import SwiftUI

/// Design tokens matching `thumbs-out`: rounded tiles, semantic colors, and crisp typography.
enum Theme {
    /// Armed / active green (#34E07F).
    static let working = Color(red: 0.204, green: 0.878, blue: 0.498)
    /// Darker green (#0F8F47) for high-contrast labels and buttons on light backgrounds.
    static let workingInk = Color(red: 0.059, green: 0.561, blue: 0.278)
    /// Brand coral red (#FF4D42) for Tjuv's thief mask and alarm state.
    static let coral = TjuvMark.coral
    /// Darker coral ink for text/buttons.
    static let coralInk = Color(red: 0.84, green: 0.20, blue: 0.16)
    /// Brand night badge (#15142B).
    static let night = TjuvMark.night
    /// Amber (#FF9E0D) for grace period, arming, and countdown.
    static let grace = Color(red: 1.0, green: 0.62, blue: 0.05)
    /// Indigo for closed-lid mode.
    static let lid = Color.indigo
    static let running = Color.blue
    static let idle = Color.secondary

    static let panelWidth: CGFloat = 340
    static let panelPadding: CGFloat = 14
    static let tileRadius: CGFloat = 12
    static let tilePadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10

    static let tileFill = Color.primary.opacity(0.055)
    static let tileStroke = Color.primary.opacity(0.07)

    static func badgeColor(for state: AlarmState) -> Color {
        switch state {
        case .disarmed:
            return Color(white: 0.62)
        case .arming, .gracePeriod, .countdown:
            return grace
        case .armed:
            return working
        case .alarmActive:
            return coral
        }
    }
}

extension Font {
    static let heroTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    static let panelTitle = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let tileTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let statValue = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let sectionLabel = Font.system(size: 10, weight: .semibold).smallCaps()
}

/// A rounded, softly filled surface used for every block in the panel.
struct TileBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.tilePadding)
            .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .strokeBorder(Theme.tileStroke, lineWidth: 0.5)
            )
    }
}

extension View {
    func tile() -> some View { modifier(TileBackground()) }
}

/// Icon-only button with a designed hover state.
struct IconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovering ? 0.09 : 0))
            )
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Title, optional subtitle and a trailing switch: the standard row inside a tile.
struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var tint: Color = Theme.working

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.tileTitle)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            AppSwitch(title: title, isOn: $isOn, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var tint: Color = Theme.working
    var isSmall = false

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(isSmall ? .small : .regular)
            .tint(tint)
    }
}

struct FormSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var tint: Color = Theme.working

    var body: some View {
        Toggle(title, isOn: $isOn).tint(tint)
    }
}

/// Interactive snap slider for motion sensitivity (`Low`, `Medium`, `High`), styled like `GraceMeter` in `thumbs-out`.
struct SensitivityMeter: View {
    @Binding var sensitivity: MotionSensitivity
    var tint: Color = Theme.working

    private let stops = MotionSensitivity.allCases
    private let trackHeight: CGFloat = 6
    private let knobSize: CGFloat = 18

    private var selectedIndex: Int {
        stops.firstIndex(of: sensitivity) ?? 1
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let step = stepWidth(for: geometry.size.width)
                ZStack(alignment: .leading) {
                    track(step: step)
                    knob.offset(x: CGFloat(selectedIndex) * step)
                }
                .frame(height: knobSize)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        select(index: Int(((value.location.x - knobSize / 2) / step).rounded()))
                    }
                )
            }
            .frame(height: knobSize)

            GeometryReader { geometry in
                let step = stepWidth(for: geometry.size.width)
                ForEach(stops.indices, id: \.self) { index in
                    let stop = stops[index]
                    Text("\(stop.rawValue) (\(Int(stop.tiltThresholdDegrees))°)")
                        .font(.system(size: 9.5, weight: index == selectedIndex ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(index == selectedIndex ? AnyShapeStyle(Theme.workingInk) : AnyShapeStyle(.tertiary))
                        .fixedSize()
                        .position(x: knobSize / 2 + CGFloat(index) * step, y: 6)
                }
            }
            .frame(height: 12)
        }
        .animation(.snappy(duration: 0.18), value: selectedIndex)
    }

    private func stepWidth(for width: CGFloat) -> CGFloat {
        max((width - knobSize) / CGFloat(max(stops.count - 1, 1)), 1)
    }

    private func track(step: CGFloat) -> some View {
        let inset = knobSize / 2
        let selectedWidth = CGFloat(selectedIndex) * step
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(tint.opacity(0.85))
                .frame(width: selectedWidth + trackHeight)
            ForEach(stops.indices, id: \.self) { index in
                Circle()
                    .fill(index <= selectedIndex ? Color.white.opacity(0.8) : Color.primary.opacity(0.25))
                    .frame(width: 3, height: 3)
                    .offset(x: CGFloat(index) * step + (trackHeight - 3) / 2)
            }
        }
        .frame(height: trackHeight)
        .padding(.horizontal, inset - trackHeight / 2)
    }

    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: knobSize, height: knobSize)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
    }

    private func select(index: Int) {
        let clamped = min(max(index, 0), stops.count - 1)
        guard clamped != selectedIndex else { return }
        sensitivity = stops[clamped]
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
