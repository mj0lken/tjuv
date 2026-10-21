import AppKit
import SwiftUI

/// The Tjuv mark: a crest shield with an internal IMU seismograph / siren pulse on a 24-unit grid.
/// Shared by the app icon, social preview, and docs/favicon.svg.
enum TjuvMark {
    static let night = Color(red: 0x15 / 255.0, green: 0x14 / 255.0, blue: 0x2B / 255.0)
    static let coral = Color(red: 1.0, green: 0x4D / 255.0, blue: 0x42 / 255.0)
    static let armed = Color(red: 0x34 / 255.0, green: 0xE0 / 255.0, blue: 0x7F / 255.0)
    static let amber = Color(red: 1.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
    static let paper = Color(red: 0.957, green: 0.949, blue: 0.925)

    /// Crest shield outline on a 24×24 grid (y down).
    static let shield: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 12.0, y: 2.6))
        path.addLine(to: CGPoint(x: 19.6, y: 5.8))
        path.addLine(to: CGPoint(x: 19.6, y: 11.6))
        path.addCurve(
            to: CGPoint(x: 12.0, y: 21.6),
            control1: CGPoint(x: 19.6, y: 16.5),
            control2: CGPoint(x: 16.3, y: 20.3)
        )
        path.addCurve(
            to: CGPoint(x: 4.4, y: 11.6),
            control1: CGPoint(x: 7.7, y: 20.3),
            control2: CGPoint(x: 4.4, y: 16.5)
        )
        path.addLine(to: CGPoint(x: 4.4, y: 5.8))
        path.closeSubpath()
        return path
    }()

    /// IMU accelerometer waveform inside the shield.
    static let pulse: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 7.4, y: 12.0))
        path.addLine(to: CGPoint(x: 9.5, y: 12.0))
        path.addLine(to: CGPoint(x: 10.9, y: 8.4))
        path.addLine(to: CGPoint(x: 13.1, y: 15.6))
        path.addLine(to: CGPoint(x: 14.5, y: 12.0))
        path.addLine(to: CGPoint(x: 16.6, y: 12.0))
        return path
    }()

    static let outline: Path = {
        var path = shield
        path.addPath(pulse)
        return path
    }()

    static let bounds = CGRect(x: 4.4, y: 2.6, width: 15.2, height: 19.0)

    static func transform(into rect: CGRect, fraction: CGFloat) -> CGAffineTransform {
        let scale = rect.width * fraction / max(bounds.width, bounds.height)
        return CGAffineTransform(
            translationX: rect.midX - bounds.midX * scale,
            y: rect.midY - bounds.midY * scale
        ).scaledBy(x: scale, y: scale)
    }
}

struct TjuvMarkShape: Shape {
    var part: Path = TjuvMark.outline
    var fraction: CGFloat = 0.60

    func path(in rect: CGRect) -> Path {
        part.applying(TjuvMark.transform(into: rect, fraction: fraction))
    }
}

struct TjuvBadge: View {
    var color: Color = TjuvMark.coral
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(TjuvMark.night)
            TjuvMarkShape()
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.054, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: TjuvMark.night.opacity(0.25), radius: size * 0.12, y: size * 0.05)
        .accessibilityHidden(true)
    }
}
