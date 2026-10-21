import Foundation
import AppKit
import SwiftUI

/// Floating HUD window that displays visual alert and countdown above all windows.
final class FloatingAlertHUD: NSObject {
    static let shared = FloatingAlertHUD()
    
    private var window: NSPanel?
    private var model = HUDViewModel()
    
    override init() {
        super.init()
    }
    
    func showCountdown(secondsRemaining: Int, reason: String, onDisarm: @escaping () -> Void) {
        model.state = .countdown(seconds: secondsRemaining, reason: reason)
        model.onDisarm = onDisarm
        presentWindowIfNeeded()
    }
    
    func updateCountdown(secondsRemaining: Int) {
        if case .countdown(_, let reason) = model.state {
            model.state = .countdown(seconds: secondsRemaining, reason: reason)
        }
    }
    
    func showAlarm(reason: String, onDisarm: @escaping () -> Void) {
        model.state = .alarm(reason: reason)
        model.onDisarm = onDisarm
        presentWindowIfNeeded()
    }
    
    func hide() {
        window?.orderOut(nil)
        window = nil
    }
    
    private func presentWindowIfNeeded() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.canBecomeVisibleWithoutLogin = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.center()
            
            let contentView = HUDContentView(model: model)
            panel.contentView = NSHostingView(rootView: contentView)
            self.window = panel
        }
        
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum HUDState {
    case countdown(seconds: Int, reason: String)
    case alarm(reason: String)
}

final class HUDViewModel: ObservableObject {
    @Published var state: HUDState = .countdown(seconds: 5, reason: "Movement detected")
    var onDisarm: (() -> Void)?
}

struct HUDContentView: View {
    @ObservedObject var model: HUDViewModel
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(isAlarm ? Color.red.opacity(0.6) : Color.orange.opacity(0.4), lineWidth: 2)
                )
            
            VStack(spacing: 16) {
                switch model.state {
                case .countdown(let seconds, let reason):
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.orange)
                        .symbolEffect(.bounce, value: seconds)
                    
                    VStack(spacing: 4) {
                        Text("Motion Detected!")
                            .font(.system(size: 20, weight: .bold))
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Alarm sounding in \(seconds)s")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange)
                    
                case .alarm(let reason):
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 46))
                        .foregroundColor(.red)
                        .symbolEffect(.pulse)
                    
                    VStack(spacing: 4) {
                        Text("TJUV ALARM ACTIVE")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundColor(.red)
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Playing on Built-in Speakers at 100%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Button(action: {
                    model.onDisarm?()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.open.fill")
                        Text("Disarm Alarm")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isAlarm ? Color.red : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(24)
        }
        .frame(width: 360, height: 260)
    }
    
    private var isAlarm: Bool {
        if case .alarm = model.state { return true }
        return false
    }
}
