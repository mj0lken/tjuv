import AppKit
import SwiftUI

/// All settings on one scrolling page, grouped into sections (matching `SettingsView` in `thumbs-out`).
struct SettingsView: View {
    let showWelcome: () -> Void
    let reportProblem: () -> Void

    @ObservedObject private var coordinator = AlarmCoordinator.shared
    @ObservedObject private var sleepManager = SleepManager.shared
    @ObservedObject private var updates = UpdateChecker.shared

    @State private var sensitivity = MotionDetector.shared.sensitivity
    @State private var armingDelay = AlarmCoordinator.shared.armingDelaySeconds
    @State private var countdownDuration = AlarmCoordinator.shared.countdownDurationSeconds
    @State private var requireCharger = AlarmCoordinator.shared.requireChargerToArm
    @State private var lockOnTrigger = AlarmCoordinator.shared.lockScreenOnTrigger
    @State private var lockOnLidClose = AlarmCoordinator.shared.lockScreenOnLidClose
    @State private var triggerPower = SystemTriggers.shared.triggerOnPowerUnplugged
    @State private var triggerLid = SystemTriggers.shared.triggerOnLidOpened
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var checksAutomatically = UpdateChecker.shared.checksAutomatically

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

            LabeledContent("Motion grace period", value: "3 seconds (two short warning beeps)")

            Picker("Countdown before siren", selection: Binding(
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
            Text("When motion first trips while armed, Tjuv plays two short warning beeps and gives you 3 seconds to put the MacBook down still before starting the Touch ID disarm countdown.")
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
        } header: {
            Text("Sensors & Triggers")
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
        Section {
            FormSwitch(title: "Check for updates automatically", isOn: Binding(
                get: { checksAutomatically },
                set: {
                    checksAutomatically = $0
                    updates.checksAutomatically = $0
                }
            ))
            LabeledContent("Version", value: updates.currentVersion?.description ?? "development build")
            HStack(spacing: 8) {
                updateStatusText
                Spacer()
                if let release = updates.availableUpdate {
                    Button("Download…") { NSWorkspace.shared.open(release.pageURL) }
                }
                Button("Check Now") {
                    updates.checkNow(completion: nil)
                }
                .disabled(updates.status == .checking || updates.currentVersion == nil)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Once a day, Tjuv asks GitHub for the latest release. Installed with Homebrew? Update with \(UpdateChecker.homebrewCommand).")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updateStatusText: some View {
        switch (updates.status, updates.availableUpdate) {
        case (.checking, _):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case (.failed(let msg), _):
            Text("Couldn't check: \(msg)").foregroundStyle(.red)
        case (_, .some(let release)):
            Text("Tjuv \(release.version.description) is available").foregroundStyle(Theme.workingInk)
        case (.upToDate, nil):
            Text("Up to date").foregroundStyle(.secondary)
        case (.idle, nil):
            Text(updates.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                .foregroundStyle(.secondary)
        }
    }
}
