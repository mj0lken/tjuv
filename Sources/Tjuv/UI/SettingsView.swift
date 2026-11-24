import AppKit
import SwiftUI

/// All settings on one scrolling page, grouped into sections (matching `SettingsView` in `thumbs-out`).
struct SettingsView: View {
    let showWelcome: () -> Void
    let reportProblem: () -> Void

    @ObservedObject private var coordinator = AlarmCoordinator.shared
    @ObservedObject private var sleepManager = SleepManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var installer = UpdateInstaller.shared

    @State private var sensitivity = MotionDetector.shared.sensitivity
    @State private var armingDelay = AlarmCoordinator.shared.armingDelaySeconds
    @State private var countdownDuration = AlarmCoordinator.shared.countdownDurationSeconds
    @State private var requireCharger = AlarmCoordinator.shared.requireChargerToArm
    @State private var lockOnTrigger = AlarmCoordinator.shared.lockScreenOnTrigger
    @State private var lockOnLidClose = AlarmCoordinator.shared.lockScreenOnLidClose
    @State private var triggerPower = SystemTriggers.shared.triggerOnPowerUnplugged
    @State private var triggerLid = SystemTriggers.shared.triggerOnLidOpened
    @State private var triggerPowerButton = SystemTriggers.shared.triggerOnPowerButton
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var checksAutomatically = UpdateChecker.shared.checksAutomatically
    @State private var didCopyHomebrew = false

    var body: some View {
        Form {
            armingSection
            triggersSection
            lidClosedSection
            stolenModeSection
            generalSection
            updatesSection
        }
        .formStyle(.grouped)
        .tint(Theme.working)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 540, idealHeight: 700)
        .onAppear {
            sleepManager.refreshSetupStatus()
        }
    }

    private var armingSection: some View {
        Section {
            Picker("Arming delay", selection: Binding(
                get: { armingDelay },
                set: {
                    armingDelay = $0
                    coordinator.armingDelaySeconds = $0
                }
            )) {
                Text("0 seconds (Immediate)").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }

            LabeledContent("Motion grace period", value: "5 seconds (warning beeps · auto-cancels when flat & still)")

            Picker("Countdown before siren (lid open)", selection: Binding(
                get: { countdownDuration },
                set: {
                    countdownDuration = $0
                    coordinator.countdownDurationSeconds = $0
                }
            )) {
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }

            FormSwitch(title: "Require charger connected to arm", isOn: Binding(
                get: { requireCharger },
                set: {
                    requireCharger = $0
                    coordinator.requireChargerToArm = $0
                }
            ))

            FormSwitch(title: "Lock screen immediately on trigger", isOn: Binding(
                get: { lockOnTrigger },
                set: {
                    lockOnTrigger = $0
                    coordinator.lockScreenOnTrigger = $0
                }
            ))
        } header: {
            Text("Arming & Grace Period")
        } footer: {
            Text("Small nudges are ignored. When the laptop is moved while armed, Tjuv plays warning beeps for 5 seconds—return the MacBook to a flat and still position within 5 seconds and it cancels automatically without unlocking.")
                .foregroundStyle(.secondary)
        }
    }

    private var triggersSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Motion sensitivity (800 Hz IMU)")
                    Spacer()
                    Text("\(sensitivity.rawValue) (±\(String(format: "%.2f", sensitivity.accelerationThreshold)) g · \(Int(sensitivity.tiltThresholdDegrees))°)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                SensitivityMeter(
                    sensitivity: Binding(
                        get: { sensitivity },
                        set: {
                            sensitivity = $0
                            MotionDetector.shared.sensitivity = $0
                        }
                    )
                )
            }
            .padding(.vertical, 4)

            FormSwitch(title: "Trigger when power adapter is unplugged", isOn: Binding(
                get: { triggerPower },
                set: {
                    triggerPower = $0
                    SystemTriggers.shared.triggerOnPowerUnplugged = $0
                }
            ))

            FormSwitch(title: "Trigger when closed lid is opened or woken", isOn: Binding(
                get: { triggerLid },
                set: {
                    triggerLid = $0
                    SystemTriggers.shared.triggerOnLidOpened = $0
                }
            ))

            FormSwitch(title: "Beep on power button press & blast siren if held (≥ 1s)", isOn: Binding(
                get: { triggerPowerButton },
                set: {
                    triggerPowerButton = $0
                    SystemTriggers.shared.triggerOnPowerButton = $0
                }
            ))
        } header: {
            Text("Sensors & Triggers")
        } footer: {
            Text("Holding a MacBook's physical power button for ~10 seconds forces a hardware PMU power-off that no software can block. Tjuv reads the hardware button switch (AppleM68Buttons) to play warning beeps on the first press and blast the 100% siren after 1 second of holding—giving ~9 seconds of full-volume alarm before hardware power-off.")
                .foregroundStyle(.secondary)
        }
    }

    private var lidClosedSection: some View {
        Section {
            FormSwitch(
                title: "Protect with the lid closed",
                isOn: Binding(
                    get: { sleepManager.isBusy || (sleepManager.closedLidProtectionEnabled && sleepManager.isSetUp) },
                    set: { sleepManager.setClosedLidMode($0) }
                ),
                tint: Theme.lid
            )
            .disabled(sleepManager.isBusy)

            if ScreenLocker.isAvailable {
                FormSwitch(title: "Lock the screen when the lid closes", isOn: Binding(
                    get: { lockOnLidClose },
                    set: {
                        lockOnLidClose = $0
                        coordinator.lockScreenOnLidClose = $0
                    }
                ), tint: Theme.lid)
                .disabled(!sleepManager.closedLidProtectionEnabled || !sleepManager.isSetUp)
            }

            LabeledContent("Sudoers helper (/etc/sudoers.d/tjuv)", value: sleepManager.isSetUp ? "Installed" : "Not set up")

            if sleepManager.isSetUp {
                Button("Remove Lid-Closed Setup…", role: .destructive) {
                    sleepManager.uninstallPasswordlessHelper { _, _ in
                        sleepManager.refreshSetupStatus()
                    }
                }
                .disabled(sleepManager.isBusy)
            }

            if let error = sleepManager.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Lid Closed")
        } footer: {
            Text("Turns lid sleep off only while Tjuv is armed, and automatically restores it when you disarm, quit, or drop below 8% battery.")
                .foregroundStyle(.secondary)
        }
    }

    private var stolenModeSection: some View {
        let findMy = FindMyDetector.currentStatus
        return Section("Stolen Mode & Speaker Lock") {
            HStack {
                Text("Find My Mac (AirTag Beacon)")
                Spacer()
                Text(findMy == .enabled ? "Active" : "Off")
                    .foregroundStyle(findMy == .enabled ? Theme.workingInk : .orange)
                if findMy != .enabled {
                    Button("Open iCloud Settings…") {
                        FindMyDetector.openSystemSettings()
                    }
                }
            }
            LabeledContent("Built-in speaker routing", value: AudioController.shared.findBuiltInSpeakerID() != nil ? "Ready (bypasses AirPods)" : "Not found")
            HStack {
                Text("Audio preview")
                Spacer()
                Button("Test 2-Beep Warning") {
                    AudioController.shared.playGraceWarningDoubleBeep()
                }
                Button("Test 1.5s Siren") {
                    AudioController.shared.testSiren()
                }
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            FormSwitch(title: "Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LaunchAtLogin.isEnabled else { return }
                    launchAtLoginError = LaunchAtLogin.setEnabled(enabled)
                    if launchAtLoginError != nil { launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let launchAtLoginError {
                Text(launchAtLoginError).foregroundStyle(.red).font(.callout)
            } else if LaunchAtLogin.needsApproval {
                Text("Approve Tjuv in System Settings › General › Login Items.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            Button("Show Welcome Again…", action: showWelcome)
            Button("Report a Bug…", action: reportProblem)
        }
    }

    private var updatesSection: some View {
        let canSelfUpdate = UpdateInstaller.canSelfUpdate(isHomebrewInstall: updates.isHomebrewInstall)
        return Section {
            FormSwitch(title: "Check for updates automatically", isOn: Binding(
                get: { checksAutomatically },
                set: {
                    checksAutomatically = $0
                    updates.checksAutomatically = $0
                }
            ))
            LabeledContent("Version", value: updates.currentVersion?.description ?? "development build")
            HStack(spacing: 8) {
                updateStatusText(canSelfUpdate: canSelfUpdate)
                Spacer()
                if let release = updates.availableUpdate {
                    if canSelfUpdate {
                        if !installer.isBusy {
                            Button("Notes") { NSWorkspace.shared.open(release.pageURL) }
                            Button("Update Now") { installer.installOrRefresh(release) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!UpdateInstaller.isSafeToRestart(coordinator.state))
                        }
                    } else if updates.isHomebrewInstall {
                        Button(didCopyHomebrew ? "Copied" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(UpdateChecker.homebrewCommand, forType: .string)
                            didCopyHomebrew = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopyHomebrew = false }
                        }
                        Button("Notes") { NSWorkspace.shared.open(release.pageURL) }
                    } else {
                        Button("Download…") { NSWorkspace.shared.open(release.pageURL) }
                    }
                }
                Button("Check Now") {
                    installer.resetError()
                    updates.checkNow(completion: nil)
                }
                .disabled(updates.status == .checking || installer.isBusy || updates.currentVersion == nil)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Tjuv automatically checks GitHub every 30 minutes and on wake or activation, and can download, verify, and install updates in one click.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func updateStatusText(canSelfUpdate: Bool) -> some View {
        switch installer.phase {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying update…").foregroundStyle(.secondary)
            }
        case .restarting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Restarting Tjuv…").foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Text(msg).foregroundStyle(Theme.coralInk)
        case .idle:
            switch (updates.status, updates.availableUpdate) {
            case (.checking, _):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            case (.failed(let msg), _):
                Text("Couldn't check: \(msg)").foregroundStyle(.red)
            case (_, .some(let release)):
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Theme.workingInk)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tjuv \(release.version.description) is available")
                            .foregroundStyle(Theme.workingInk)
                        if canSelfUpdate && !UpdateInstaller.isSafeToRestart(coordinator.state) {
                            Text("Turn the alarm off to update")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !canSelfUpdate && updates.isHomebrewInstall {
                            Text(UpdateChecker.homebrewCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            case (.upToDate, nil):
                Text("Up to date").foregroundStyle(.secondary)
            case (.idle, nil):
                Text(updates.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
