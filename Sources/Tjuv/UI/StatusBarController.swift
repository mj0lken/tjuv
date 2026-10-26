import AppKit
import SwiftUI

/// Controls the macOS menu bar item, displaying the thief eye mask glyph and presenting the SwiftUI `MenuPanel` popover.
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var flashTimer: Timer?
    private var eventMonitor: Any?

    override init() {
        super.init()
        setupStatusBar()
        setupPopover()
        observeCoordinator()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        updateIcon(for: .disarmed)
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        let panel = MenuPanel(
            openSettings: { WindowManager.shared.showSettings() },
            reportProblem: { WindowManager.shared.showReportProblem() },
            closePopover: { [weak self] in self?.closePopover() }
        )
        let controller = NSHostingController(rootView: panel)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        SleepManager.shared.refreshSetupStatus()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func observeCoordinator() {
        AlarmCoordinator.shared.onStateChanged = { [weak self] newState in
            DispatchQueue.main.async {
                self?.updateIcon(for: newState)
            }
        }
    }

    // MARK: - Icon Updating

    private func updateIcon(for state: AlarmState) {
        guard let button = statusItem.button else { return }

        flashTimer?.invalidate()
        flashTimer = nil
        button.title = ""

        switch state {
        case .disarmed:
            button.image = MenuBarGlyph.image(filled: false)
            button.contentTintColor = .tertiaryLabelColor

        case .standby:
            button.image = MenuBarGlyph.image(filled: false)
            button.contentTintColor = nil

        case .arming(let remaining):
            button.image = MenuBarGlyph.image(filled: false)
            button.title = " \(remaining)s"
            button.contentTintColor = .systemOrange

        case .armed:
            button.image = MenuBarGlyph.image(filled: true)
            button.contentTintColor = .systemGreen

        case .gracePeriod(let remaining):
            button.image = MenuBarGlyph.image(filled: true)
            button.title = " \(remaining)s"
            button.contentTintColor = .systemYellow

        case .countdown(let remaining, _):
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Tjuv Triggered")
            button.title = " \(remaining)s"
            button.contentTintColor = .systemOrange
            startFlashingIcon(symbol1: "bell.badge.fill", symbol2: "bell.fill", color: .systemOrange)

        case .alarmActive:
            button.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Tjuv Alarm Blaring")
            button.title = " ALARM"
            button.contentTintColor = .systemRed
            startFlashingIcon(symbol1: "speaker.wave.3.fill", symbol2: "bell.fill", color: .systemRed)
        }
    }

    private func startFlashingIcon(symbol1: String, symbol2: String, color: NSColor) {
        var toggle = false
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let button = self?.statusItem.button else { return }
                toggle.toggle()
                button.image = NSImage(systemSymbolName: toggle ? symbol1 : symbol2, accessibilityDescription: "Alarm")
                button.contentTintColor = toggle ? color : .labelColor
            }
        }
    }
}
