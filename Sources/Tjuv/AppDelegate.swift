import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var wakeObserver: NSObjectProtocol?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run purely in menu bar with no Dock icon
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        if SiteAssetRenderer.runIfRequested() {
            return
        }
        #endif

        // Initialize status bar controller
        statusBarController = StatusBarController()

        // Start motion detector in passive monitor mode so g-force meter works
        MotionDetector.shared.startMonitoring()

        // Enter Standby (Active use) if master switch is enabled
        AlarmCoordinator.shared.start()

        // Start GitHub release update checker (30m cadence + ETag)
        UpdateChecker.shared.start()

        // Re-check for updates on system wake if the 30-minute interval has elapsed
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                UpdateChecker.shared.checkIfDue()
            }
        }

        // Show first-launch onboarding if not completed yet (or if requested via --onboarding)
        if !WindowManager.shared.hasCompletedOnboarding || CommandLine.arguments.contains("--onboarding") {
            WindowManager.shared.showOnboarding()
        }
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        UpdateChecker.shared.checkIfDue()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // Ensure sleep and volume settings are cleanly restored
        AlarmCoordinator.shared.forceDisarm()
    }
}
