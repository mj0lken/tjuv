import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

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

        // Start daily GitHub release update checker
        UpdateChecker.shared.start()

        // Show first-launch onboarding if not completed yet (or if requested via --onboarding)
        if !WindowManager.shared.hasCompletedOnboarding || CommandLine.arguments.contains("--onboarding") {
            WindowManager.shared.showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure sleep and volume settings are cleanly restored
        AlarmCoordinator.shared.forceDisarm()
    }
}
