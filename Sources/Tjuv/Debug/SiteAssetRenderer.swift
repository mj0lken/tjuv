#if DEBUG
import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only renderer (`Tjuv --render-site <dir>`) that generates the app icon, tour panels,
/// HUD screenshots, 1280×640 social preview, animated README demo.gif, and drafts/demo.mp4.
@MainActor
enum SiteAssetRenderer {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--render-site"), idx + 1 < args.count else {
            return false
        }
        let dir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            // 1. App Icon (1024px and 180px)
            let iconArt = TjuvBadge(color: TjuvMark.coral, size: 412).frame(width: 512, height: 512)
            if let cg = bitmap(of: iconArt, transparent: true)?.cgImage {
                try writePNG(scaled(cg, CGSize(width: 1024, height: 1024)), to: dir.appendingPathComponent("app-icon-1024.png"))
                try writePNG(scaled(cg, CGSize(width: 180, height: 180)), to: dir.appendingPathComponent("app-icon-180.png"))
            }

            // 2. Tour panels (684×1192 for docs/index.html scroll story)
            let states: [(String, TourPanelState)] = [
                ("disarmed", .disarmed),
                ("armed", .armed),
                ("countdown", .countdown),
                ("alarm", .alarm),
            ]
            for (name, state) in states {
                let view = TourPanelView(state: state)
                if let cg = bitmap(of: view, transparent: true)?.cgImage {
                    try writePNG(scaled(cg, CGSize(width: 684, height: 1192)), to: dir.appendingPathComponent("panel-\(name).png"))
                }
            }

            // 3. Floating HUD screenshots for README
            let countdownHUD = HUDContentView(model: {
                let m = HUDViewModel()
                m.state = .countdown(seconds: 4, reason: "Computer physically moved (0.14 g)")
                return m
            }()).padding(16)
            if let cg = bitmap(of: countdownHUD, transparent: true)?.cgImage {
                try writePNG(cg, to: dir.appendingPathComponent("hud-countdown.png"))
            }

            let alarmHUD = HUDContentView(model: {
                let m = HUDViewModel()
                m.state = .alarm(reason: "Computer physically moved · Screen Locked")
                return m
            }()).padding(16)
            if let cg = bitmap(of: alarmHUD, transparent: true)?.cgImage {
                try writePNG(cg, to: dir.appendingPathComponent("hud-alarm.png"))
            }

            // 4. Social preview (1280×640)
            if let cg = bitmap(of: TjuvSocialPreview())?.cgImage {
                try writePNG(scaled(cg, CGSize(width: 1280, height: 640)), to: dir.appendingPathComponent("social-preview.png"))
            }

            // 5. Animated demo.gif (720×497)
            let scenes: [(String, String, TourPanelState)] = [
                ("1 · Armed", "Armed in the menu bar.\n800 Hz Apple Silicon IMU active.", .armed),
                ("2 · Lid Closed", "Close the lid in a café.\nScreen locks, Mac stays on guard.", .armed),
                ("3 · Motion Detected", "Laptop lifted (0.14 g).\nFriendly 5-second countdown.", .countdown),
                ("4 · Full Siren", "100% built-in speaker siren.\nHeadphones bypassed, volume locked.", .alarm),
                ("5 · Touch ID Disarm", "Disarmed with Touch ID.\nSleep & audio restored.", .disarmed),
            ]
            let gifSize = CGSize(width: 720, height: 497)
            var gifFrames: [(CGImage, Double)] = []
            for (step, caption, state) in scenes {
                let canvas = TjuvDemoCanvas(step: step, caption: caption, state: state)
                if let cg = bitmap(of: canvas)?.cgImage {
                    gifFrames.append((scaled(cg, gifSize), 2.1))
                }
            }
            try writeGIF(gifFrames, to: dir.appendingPathComponent("demo.gif"))
        } catch {
            FileHandle.standardError.write(Data("Site asset render failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    static func bitmap(of view: some View, transparent: Bool = false) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = hosting.appearance
        window.backgroundColor = transparent ? .clear : NSColor(white: 0.96, alpha: 1)
        window.isOpaque = !transparent
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    static func scaled(_ image: CGImage, _ size: CGSize) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        ctx?.interpolationQuality = .high
        ctx?.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx?.makeImage() ?? image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    static func writeGIF(_ frames: [(CGImage, Double)], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (image, delay) in frames {
            CGImageDestinationAddImage(dest, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

enum TourPanelState {
    case disarmed
    case armed
    case countdown
    case alarm

    var statusTitle: String {
        switch self {
        case .disarmed: "Disarmed"
        case .armed: "Armed & Monitoring"
        case .countdown: "Motion Detected · 4s"
        case .alarm: "SIREN ACTIVE · 100%"
        }
    }

    var statusSubtitle: String {
        switch self {
        case .disarmed: "800 Hz Apple Silicon IMU ready"
        case .armed: "Lid-closed guard & screen lock active"
        case .countdown: "Screen locked · Friendly warning beeps"
        case .alarm: "Built-in speakers locked at max volume"
        }
    }

    var badgeColor: Color {
        switch self {
        case .disarmed: Color(white: 0.55)
        case .armed: TjuvMark.armed
        case .countdown: TjuvMark.amber
        case .alarm: TjuvMark.coral
        }
    }

    var deltaGText: String {
        switch self {
        case .disarmed: "0.002 g"
        case .armed: "0.003 g"
        case .countdown: "0.142 g  ⚠️"
        case .alarm: "0.318 g  🚨"
        }
    }

    var buttonTitle: String {
        switch self {
        case .disarmed: "Arm Alarm (⌘A)"
        case .armed: "Disarm with Touch ID (⌘D)"
        case .countdown: "Disarm Now with Touch ID"
        case .alarm: "DISARM SIREN (Touch ID)"
        }
    }
}

struct TourPanelView: View {
    let state: TourPanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header card
            HStack(spacing: 12) {
                TjuvBadge(color: state.badgeColor, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.statusTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(TjuvMark.night)
                    Text(state.statusSubtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(TjuvMark.night.opacity(0.62))
                }
                Spacer()
                Circle()
                    .fill(state.badgeColor)
                    .frame(width: 10, height: 10)
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            // Primary Action
            HStack {
                Image(systemName: state == .disarmed ? "shield.fill" : "touchid")
                Text(state.buttonTitle)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(state == .alarm ? TjuvMark.coral : (state == .countdown ? TjuvMark.amber : TjuvMark.night), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            // IMU & Triggers Tile
            VStack(alignment: .leading, spacing: 7) {
                Text("SENSORS & TRIGGERS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(TjuvMark.night.opacity(0.48))
                row(icon: "gyroscope", label: "Apple Silicon IMU (800 Hz)", value: state.deltaGText, highlight: state == .countdown || state == .alarm)
                row(icon: "powerplug.fill", label: "Power Unplugged Trigger", value: "On · AC 100%", highlight: false)
                row(icon: "macbook", label: "Lid Opened Trigger", value: "On · Medium (6°)", highlight: false)
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            // Audio & Speaker Lock Tile
            VStack(alignment: .leading, spacing: 7) {
                Text("BUILT-IN SPEAKER LOCK")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(TjuvMark.night.opacity(0.48))
                row(icon: "speaker.wave.3.fill", label: "Internal Speaker Routing", value: "Bypasses AirPods", highlight: state == .alarm)
                row(icon: "lock.fill", label: "200 ms Volume Watchdog", value: state == .alarm ? "Locked at 100%" : "Ready (100%)", highlight: state == .alarm)
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            // Closed-Lid & Stolen Mode Tile
            VStack(alignment: .leading, spacing: 7) {
                Text("CLOSED LID & STOLEN MODE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(TjuvMark.night.opacity(0.48))
                row(icon: "moon.zzz.fill", label: "Closed-Lid Protection", value: state == .disarmed ? "Ready (sudoers ✓)" : "Active · Watchdog ✓", highlight: state != .disarmed)
                row(icon: "lock.display", label: "Screen Lock (Lid / Trigger)", value: "Immediate (⌃⌘Q)", highlight: false)
                row(icon: "location.fill.viewfinder", label: "Find My Beacon (AirTag)", value: "Active in NVRAM", highlight: false)
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            // Footer
            HStack {
                Text("Touch ID Required")
                Spacer()
                Text("Report a Bug… · Settings")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TjuvMark.night.opacity(0.5))
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 342, height: 596, alignment: .top)
        .background(Color(white: 0.955), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(icon: String, label: String, value: String, highlight: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlight ? TjuvMark.coral : TjuvMark.night.opacity(0.7))
                .frame(width: 18)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TjuvMark.night)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlight ? TjuvMark.coral : TjuvMark.night.opacity(0.6))
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct TjuvDemoCanvas: View {
    let step: String
    let caption: String
    let state: TourPanelState

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.92, blue: 0.90), Color(red: 0.88, green: 0.90, blue: 0.97)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Mock macOS menu bar
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
                Text("Tjuv").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) {
                    Text($0).font(.system(size: 13))
                }
                Spacer()
                HStack(spacing: 4) {
                    if state == .alarm || state == .countdown {
                        Image(systemName: state == .alarm ? "speaker.wave.3.fill" : "bell.badge.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(state == .alarm ? TjuvMark.coral : TjuvMark.amber)
                    } else {
                        Image(nsImage: MenuBarGlyph.image(filled: state == .armed))
                            .renderingMode(.template)
                            .foregroundStyle(state == .armed ? TjuvMark.armed : TjuvMark.night)
                    }
                    if state == .countdown {
                        Text("4s").font(.system(size: 11, weight: .bold, design: .monospaced))
                    } else if state == .alarm {
                        Text("ALARM").font(.system(size: 11, weight: .heavy))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
                Image(systemName: "battery.100percent").font(.system(size: 15))
                Text("Wed 13:15").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(TjuvMark.night)
            .padding(.horizontal, 18)
            .frame(height: 26)
            .background(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 14) {
                Text(step)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(TjuvMark.coral)
                    .textCase(.uppercase)
                Text(caption)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(TjuvMark.night)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 520, alignment: .leading)
            .padding(.leading, 64)
            .padding(.top, 230)

            TourPanelView(state: state)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
                .offset(x: 1100 - 342 - 90, y: 42)
        }
        .frame(width: 1100, height: 760)
        .clipped()
    }
}

struct TjuvSocialPreview: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            TjuvMark.paper
            Circle()
                .fill(TjuvMark.coral.opacity(0.15))
                .frame(width: 720, height: 720)
                .blur(radius: 60)
                .offset(x: 700, y: -160)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 18) {
                    TjuvBadge(color: TjuvMark.coral, size: 76)
                    Text("Tjuv")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .foregroundStyle(TjuvMark.night)
                }
                .padding(.bottom, 36)
                Text("Touch my MacBook.\nEverybody hears it.")
                    .font(.system(size: 62, weight: .heavy, design: .rounded))
                    .foregroundStyle(TjuvMark.night)
                    .lineSpacing(2)
                    .padding(.bottom, 24)
                Text("800 Hz Apple Silicon motion alarm with built-in speaker\nlock, closed-lid protection, screen lock & Touch ID disarm.")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
                    .foregroundStyle(TjuvMark.night.opacity(0.64))
                Spacer()
                Text("Free & open source · macOS menu bar app")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(TjuvMark.coral)
            }
            .padding(.leading, 72)
            .padding(.vertical, 64)

            TourPanelView(state: .armed)
                .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
                .scaleEffect(0.88, anchor: .topLeading)
                .rotationEffect(.degrees(3), anchor: .topLeading)
                .offset(x: 890, y: 64)
        }
        .frame(width: 1280, height: 640)
        .clipped()
    }
}
#endif
