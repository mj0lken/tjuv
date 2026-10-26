import AppKit
import SwiftUI

/// The rich menu bar popover panel, styled directly after `thumbs-out`.
struct MenuPanel: View {
    @ObservedObject var coordinator = AlarmCoordinator.shared
    @ObservedObject var sleepManager = SleepManager.shared
    @ObservedObject var updates = UpdateChecker.shared

    let openSettings: () -> Void
    let reportProblem: () -> Void
    let closePopover: () -> Void

    @State private var armErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if let release = updates.availableUpdate {
                UpdateBanner(release: release, isHomebrewInstall: updates.isHomebrewInstall)
            }

            StatusHeader(
                coordinator: coordinator,
                sleepManager: sleepManager,
                armErrorMessage: $armErrorMessage
            )

            if let armErrorMessage {
                Text(armErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            SensorStrip(coordinator: coordinator)

            TriggersTile(coordinator: coordinator)

            SensitivityTile()

            LidTile(sleepManager: sleepManager, coordinator: coordinator)

            StolenModeTile()

            ReportBugRow {
                closePopover()
                reportProblem()
            }

            PanelFooter(
                coordinator: coordinator,
                openSettings: {
                    closePopover()
                    openSettings()
                }
            )
        }
        .padding(Theme.panelPadding)
        .frame(width: Theme.panelWidth)
        .tint(Theme.working)
        .onAppear {
            sleepManager.refreshSetupStatus()
        }
    }
}

private struct StatusHeader: View {
    @ObservedObject var coordinator: AlarmCoordinator
    @ObservedObject var sleepManager: SleepManager
    @Binding var armErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TjuvBadge(color: Theme.badgeColor(for: coordinator.state), size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.panelTitle)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                AppSwitch(
                    title: coordinator.state.isEnabled ? "Turn Tjuv Off" : "Turn Tjuv On",
                    isOn: Binding(
                        get: { coordinator.state.isEnabled },
                        set: { wantEnabled in
                            armErrorMessage = nil
                            coordinator.setMasterEnabled(wantEnabled)
                        }
                    ),
                    tint: switchTint
                )
                .help(coordinator.state.isEnabled ? "Turn Tjuv off" : "Turn Tjuv on (Standby during active use)")
            }

            if coordinator.state == .standby {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.workingInk)
                    Text("Arms automatically on lid close or screen lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Lock & Arm") {
                        armErrorMessage = nil
                        let res = coordinator.lockAndArmNow()
                        if !res.success {
                            armErrorMessage = res.message
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.workingInk)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private var switchTint: Color {
        switch coordinator.state {
        case .disarmed, .standby, .armed: return Theme.working
        case .arming, .gracePeriod, .countdown: return Theme.grace
        case .alarmActive: return Theme.coral
        }
    }

    private var title: String {
        switch coordinator.state {
        case .disarmed:
            return "Theft guard is off"
        case .standby:
            return "Standby · Active use"
        case .arming(let s):
            return "Arming in \(s)s…"
        case .armed:
            return "Armed & monitoring"
        case .gracePeriod(let s):
            return "Put MacBook down · \(s)s"
        case .countdown(let s, _):
            return "Motion detected · \(s)s"
        case .alarmActive:
            return "Siren active (100%)"
        }
    }

    private var subtitle: String {
        switch coordinator.state {
        case .disarmed:
            return "Turn on to arm when locked or closed"
        case .standby:
            return "Unarmed while unlocked · ready to guard"
        case .arming:
            return "Keep MacBook still while calibrating"
        case .armed:
            return sleepManager.isDisabledByUs
                ? "Lid-closed guard & screen lock on"
                : "800 Hz motion & power triggers on"
        case .gracePeriod:
            return "Hold still to cancel alarm"
        case .countdown(_, let reason):
            return reason
        case .alarmActive(let reason):
            return reason
        }
    }
}

/// Three-column live sensor & timer strip, styled after `StatsStrip` in `thumbs-out`.
private struct SensorStrip: View {
    @ObservedObject var coordinator: AlarmCoordinator

    var body: some View {
        HStack(spacing: 0) {
            stat("Live ΔG", String(format: "%.3f g", coordinator.liveDeltaG))
            Divider().frame(height: 26)
            stat("Grace", "\(coordinator.gracePeriodSeconds)s · 2 beeps")
            Divider().frame(height: 26)
            stat("Countdown", "\(coordinator.countdownDurationSeconds)s")
        }
        .padding(.vertical, 8)
        .tile()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live accelerometer and timer settings")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.statValue).contentTransition(.numericText())
            Text(label).font(.sectionLabel).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Active triggers tile, styled after `AgentsTile` in `thumbs-out`.
private struct TriggersTile: View {
    @ObservedObject var coordinator: AlarmCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SENSORS & TRIGGERS")
                .font(.sectionLabel)
                .foregroundStyle(.secondary)

            sensorRow(
                icon: "gyroscope",
                tint: MotionDetector.shared.isHardwareAvailable ? Theme.working : .orange,
                title: "Apple Silicon IMU (800 Hz)",
                subtitle: MotionDetector.shared.isHardwareAvailable
                    ? "3s put-down grace (2 beeps) · +\(coordinator.countdownDurationSeconds)s countdown"
                    : "Sensor unavailable",
                trailingDot: MotionDetector.shared.isHardwareAvailable ? Theme.working : .orange
            )

            sensorSwitchRow(
                icon: "powerplug.fill",
                tint: SystemTriggers.shared.triggerOnPowerUnplugged ? Theme.running : .secondary,
                title: "Charger Unplugged",
                subtitle: "\(SystemTriggers.shared.powerStatusSummary) · 3s grace + \(coordinator.countdownDurationSeconds)s countdown",
                isOn: Binding(
                    get: { SystemTriggers.shared.triggerOnPowerUnplugged },
                    set: { SystemTriggers.shared.triggerOnPowerUnplugged = $0 }
                )
            )

            sensorSwitchRow(
                icon: "laptopcomputer",
                tint: SystemTriggers.shared.triggerOnLidOpened ? Theme.running : .secondary,
                title: "Lid Opened or Woken",
                subtitle: "Gives \(coordinator.countdownDurationSeconds)s Touch ID grace countdown on open",
                isOn: Binding(
                    get: { SystemTriggers.shared.triggerOnLidOpened },
                    set: { SystemTriggers.shared.triggerOnLidOpened = $0 }
                )
            )
        }
        .tile()
    }

    private func sensorRow(icon: String, tint: Color, title: String, subtitle: String, trailingDot: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.tileTitle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(trailingDot)
                .frame(width: 8, height: 8)
        }
    }

    private func sensorSwitchRow(icon: String, tint: Color, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.tileTitle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            AppSwitch(title: title, isOn: isOn, tint: Theme.working, isSmall: true)
        }
    }
}

/// Interactive motion sensitivity slider tile, styled after `graceTile` in `thumbs-out`.
private struct SensitivityTile: View {
    @State private var sensitivity = MotionDetector.shared.sensitivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Motion sensitivity").font(.tileTitle)
                Spacer()
                Text(sensitivity.rawValue)
                    .font(.tileTitle.monospacedDigit())
                    .foregroundStyle(Theme.workingInk)
            }
            SensitivityMeter(
                sensitivity: Binding(
                    get: { sensitivity },
                    set: { newValue in
                        sensitivity = newValue
                        MotionDetector.shared.sensitivity = newValue
                    }
                )
            )
        }
        .tile()
        .onAppear {
            sensitivity = MotionDetector.shared.sensitivity
        }
    }
}

/// Lid-closed protection tile, styled directly after `LidTile` in `thumbs-out`.
private struct LidTile: View {
    @ObservedObject var sleepManager: SleepManager
    @ObservedObject var coordinator: AlarmCoordinator

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isActive ? Theme.lid : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Protect with lid closed").font(.tileTitle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            AppSwitch(
                title: "Protect with lid closed",
                isOn: Binding(
                    get: { sleepManager.isBusy || (sleepManager.closedLidProtectionEnabled && sleepManager.isSetUp) },
                    set: { sleepManager.setClosedLidMode($0) }
                ),
                tint: Theme.lid,
                isSmall: true
            )
            .disabled(sleepManager.isBusy)
        }
        .tile()
    }

    private var isActive: Bool {
        sleepManager.closedLidProtectionEnabled && sleepManager.isSetUp
    }

    private var detail: String {
        if sleepManager.isBusy { return "Waiting for your password…" }
        if !sleepManager.isSetUp {
            return "Needs your admin password once"
        }
        if !sleepManager.closedLidProtectionEnabled {
            return "Off: Mac sleeps when closed"
        }
        if sleepManager.isDisabledByUs {
            return "On: stays awake & locks screen when closed"
        }
        return "Ready: kicks in while armed"
    }
}

/// Compact stolen-mode status tile showing Find My Beacon (AirTag) and Built-in Speaker Lock.
private struct StolenModeTile: View {
    @State private var findMyStatus = FindMyDetector.currentStatus

    var body: some View {
        Button {
            if findMyStatus != .enabled {
                FindMyDetector.openSystemSettings()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(findMyStatus == .enabled ? Theme.working : Theme.grace)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Find My AirTag Beacon & Speaker Lock").font(.tileTitle)
                    Text(findMyStatus == .enabled
                        ? "Offline P-224 beacon active · 100% built-in speaker lock"
                        : "Find My Mac is off · click to enable AirTag tracking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(findMyStatus == .enabled ? Theme.working : Theme.grace)
                    .frame(width: 8, height: 8)
            }
            .tile()
            .contentShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear {
            findMyStatus = FindMyDetector.currentStatus
        }
    }
}

/// Tops the panel while a newer release is out.
struct UpdateBanner: View {
    let release: LatestRelease
    let isHomebrewInstall: Bool
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.working)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(release.version.description) is available").font(.tileTitle)
                Text(isHomebrewInstall ? UpdateChecker.homebrewCommand : "See what's new and download it")
                    .font(isHomebrewInstall ? .caption.monospaced() : .caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if isHomebrewInstall {
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UpdateChecker.homebrewCommand, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopy = false }
                }
            }
            Button(isHomebrewInstall ? "Notes" : "Download") {
                NSWorkspace.shared.open(release.pageURL)
            }
        }
        .controlSize(.small)
        .tile()
    }
}

struct ReportBugRow: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "ladybug")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text("Report a Bug…").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(isHovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct PanelFooter: View {
    @ObservedObject var coordinator: AlarmCoordinator
    let openSettings: () -> Void
    @State private var isTestingBeeps = false

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Test Lid-Closed Lock Sound") {
                    AudioController.shared.playLidLockedSound()
                }
                Button("Test 2-Beep Grace Warning") {
                    AudioController.shared.playGraceWarningDoubleBeep()
                }
                Button("Test Friendly Countdown Beep") {
                    AudioController.shared.playFriendlyCountdownBeep()
                }
                Divider()
                Button("Test 1.5s Siren (100% Built-in Speaker)") {
                    AudioController.shared.testSiren()
                }
            } label: {
                Label("Test audio & siren…", systemImage: "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.workingInk)
            .fixedSize()
            .padding(.leading, 4)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                switch coordinator.state {
                case .disarmed, .standby:
                    coordinator.forceDisarm()
                    NSApplication.shared.terminate(nil)
                case .arming, .armed, .gracePeriod, .countdown, .alarmActive:
                    AuthManager.shared.authenticateToDisarm { success in
                        if success {
                            coordinator.forceDisarm()
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("Quit Tjuv")
            .accessibilityLabel("Quit Tjuv")
        }
    }
}
