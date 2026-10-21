import AppKit
import SwiftUI

/// Opens the onboarding, settings and report windows on demand, matching `WindowManager` in `thumbs-out`.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private static let onboardingKey = "hasCompletedOnboarding"

    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var reportWindow: NSWindow?

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    func showOnboarding() {
        if let onboardingWindow {
            present(onboardingWindow)
            return
        }
        let view = OnboardingView(suggestLaunchAtLogin: !hasCompletedOnboarding) { [weak self] in
            self?.onboardingWindow?.close()
        }
        let window = makeWindow(content: view, title: "Welcome to Tjuv")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        onboardingWindow = window
        present(window)
    }

    func showSettings() {
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let view = SettingsView(
            showWelcome: { [weak self] in self?.showOnboarding() },
            reportProblem: { [weak self] in self?.showReportProblem() }
        )
        let window = makeWindow(content: view, title: "Tjuv Settings")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 700))
        window.setFrameAutosaveName("TjuvSettingsWindow")
        settingsWindow = window
        present(window)
    }

    func showReportProblem() {
        if let reportWindow {
            present(reportWindow)
            return
        }
        let view = ReportProblemView { [weak self] in
            self?.reportWindow?.close()
        }
        let window = makeWindow(content: view, title: "Report a Bug")
        window.styleMask = [.titled, .closable, .miniaturizable]
        reportWindow = window
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            UserDefaults.standard.set(true, forKey: Self.onboardingKey)
            onboardingWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        } else if window === reportWindow {
            reportWindow = nil
        }
    }

    private func makeWindow(content: some View, title: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
