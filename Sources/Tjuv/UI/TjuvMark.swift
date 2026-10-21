import AppKit
import SwiftUI

/// The Tjuv mark: a classic domino thief eye mask on a 24-unit grid (y down).
/// Shared by the app icon, menu bar glyph, social preview, and docs/favicon.svg.
enum TjuvMark {
    static let night = Color(red: 0x15 / 255.0, green: 0x14 / 255.0, blue: 0x2B / 255.0)
    static let coral = Color(red: 1.0, green: 0x4D / 255.0, blue: 0x42 / 255.0)
    static let armed = Color(red: 0x34 / 255.0, green: 0xE0 / 255.0, blue: 0x7F / 255.0)
    static let amber = Color(red: 1.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
    static let paper = Color(red: 0.957, green: 0.949, blue: 0.925)

    /// Outer contour of the domino thief mask: twin brow arches and a nose-bridge notch below.
    static let maskOuter: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 12.0, y: 7.8))
        path.addCurve(
            to: CGPoint(x: 18.2, y: 6.2),
            control1: CGPoint(x: 14.2, y: 7.8),
            control2: CGPoint(x: 15.8, y: 6.2)
        )
        path.addCurve(
            to: CGPoint(x: 22.4, y: 11.4),
            control1: CGPoint(x: 20.8, y: 6.2),
            control2: CGPoint(x: 22.4, y: 8.0)
        )
        path.addCurve(
            to: CGPoint(x: 17.2, y: 17.6),
            control1: CGPoint(x: 22.4, y: 15.0),
            control2: CGPoint(x: 20.2, y: 17.6)
        )
        path.addCurve(
            to: CGPoint(x: 12.0, y: 14.2),
            control1: CGPoint(x: 14.8, y: 17.6),
            control2: CGPoint(x: 13.6, y: 14.2)
        )
        path.addCurve(
            to: CGPoint(x: 6.8, y: 17.6),
            control1: CGPoint(x: 10.4, y: 14.2),
            control2: CGPoint(x: 9.2, y: 17.6)
        )
        path.addCurve(
            to: CGPoint(x: 1.6, y: 11.4),
            control1: CGPoint(x: 3.8, y: 17.6),
            control2: CGPoint(x: 1.6, y: 15.0)
        )
        path.addCurve(
            to: CGPoint(x: 5.8, y: 6.2),
            control1: CGPoint(x: 1.6, y: 8.0),
            control2: CGPoint(x: 3.2, y: 6.2)
        )
        path.addCurve(
            to: CGPoint(x: 12.0, y: 7.8),
            control1: CGPoint(x: 8.2, y: 6.2),
            control2: CGPoint(x: 9.8, y: 7.8)
        )
        path.closeSubpath()
        return path
    }()

    /// Left angled eye hole.
    static let leftEye: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 4.4, y: 11.3))
        path.addCurve(
            to: CGPoint(x: 9.8, y: 11.8),
            control1: CGPoint(x: 5.2, y: 9.5),
            control2: CGPoint(x: 8.2, y: 9.7)
        )
        path.addCurve(
            to: CGPoint(x: 4.4, y: 11.3),
            control1: CGPoint(x: 8.6, y: 13.5),
            control2: CGPoint(x: 5.4, y: 13.4)
        )
        path.closeSubpath()
        return path
    }()

    /// Right angled eye hole (mirror of leftEye across x = 12).
    static let rightEye: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 19.6, y: 11.3))
        path.addCurve(
            to: CGPoint(x: 14.2, y: 11.8),
            control1: CGPoint(x: 18.8, y: 9.5),
            control2: CGPoint(x: 15.8, y: 9.7)
        )
        path.addCurve(
            to: CGPoint(x: 19.6, y: 11.3),
            control1: CGPoint(x: 15.4, y: 13.5),
            control2: CGPoint(x: 18.6, y: 13.4)
        )
        path.closeSubpath()
        return path
    }()

    static let outline: Path = {
        var path = maskOuter
        path.addPath(leftEye)
        path.addPath(rightEye)
        return path
    }()

    static let bounds = CGRect(x: 1.6, y: 6.2, width: 20.8, height: 11.4)

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
    var fraction: CGFloat = 0.68

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
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.052, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: TjuvMark.night.opacity(0.25), radius: size * 0.12, y: size * 0.05)
        .accessibilityHidden(true)
    }
}

/// Template image for the macOS menu bar: outlined thief mask when disarmed, filled mask (with
/// cutout eye holes) when armed.
enum MenuBarGlyph {
    static func image(filled: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let transform = TjuvMark.transform(into: CGRect(origin: .zero, size: size), fraction: 0.92)
            if filled {
                context.addPath(TjuvMark.outline.applying(transform).cgPath)
                context.fillPath(using: .evenOdd)
            } else {
                context.addPath(TjuvMark.outline.applying(transform).cgPath)
                context.setLineWidth(1.35)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = filled ? "Tjuv Armed" : "Tjuv Disarmed"
        return image
    }
}
