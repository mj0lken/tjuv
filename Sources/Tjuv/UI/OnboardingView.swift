import AppKit
import SwiftUI

/// First-launch walkthrough, styled directly after `OnboardingView` in `thumbs-out`.
struct OnboardingView: View {
    let finish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, sensors, grace, lid, done
    }

    @State private var step: Step
    @State private var isMovingForward = true
    @State private var launchAtLogin: Bool
    @State private var launchAtLoginError: String?

    init(
        initialStep: Step = .welcome,
        suggestLaunchAtLogin: Bool = true,
        finish: @escaping () -> Void
    ) {
        self.finish = finish
        _step = State(initialValue: initialStep)
        _launchAtLogin = State(initialValue: suggestLaunchAtLogin || LaunchAtLogin.isEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepContent
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .offset(x: isMovingForward ? 40 : -40).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 48)
            .padding(.bottom, 24)

            Divider()
            bottomBar
        }
        .frame(width: 600, height: 580)
        .background(.background)
        .tint(Theme.working)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .sensors: SensorsStep()
        case .grace: GraceAndCountdownStep()
        case .lid: LidAndFindMyStep()
        case .done: DoneStep(launchAtLogin: $launchAtLogin, error: launchAtLoginError)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? Theme.working : Color.primary.opacity(0.15))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .animation(.snappy, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Spacer()

            if step != .welcome {
                Button("Back") { move(by: -1) }
                    .keyboardShortcut(.cancelAction)
            }
            Button(primaryTitle) {
                if step == .done { complete() } else { move(by: 1) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(Theme.workingInk)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Start Using Tjuv"
        default: "Continue"
        }
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        isMovingForward = offset > 0
        withAnimation(.snappy(duration: 0.28)) { step = next }
    }

    private func complete() {
        launchAtLoginError = LaunchAtLogin.setEnabled(launchAtLogin)
        if launchAtLoginError == nil { finish() }
    }
}

private struct StepHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TjuvBadge(color: Theme.coral, size: 84)
                .padding(.bottom, 26)
            Text("Tjuv.").font(.heroTitle)
            Text("Touch my MacBook. Everybody hears it. Walk away for two minutes in a café, library or airport lounge without packing up your desk.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 16) {
                feature("gyroscope", Theme.working, "Reads your MacBook's 800 Hz Apple Silicon motion sensor, charger and lid")
                feature("hand.raised.fill", Theme.grace, "Two short warning beeps give you 3 seconds to put the laptop back down still")
                feature("speaker.wave.3.fill", Theme.coral, "Locks the screen and blasts a 100% siren on the built-in speakers—even with AirPods in")
            }
        }
    }

    private func feature(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text).font(.body)
        }
    }
}

private struct SensorsStep: View {
    @ObservedObject private var coordinator = AlarmCoordinator.shared
    @State private var sensitivity = MotionDetector.shared.sensitivity
    @State private var triggerPower = SystemTriggers.shared.triggerOnPowerUnplugged
    @State private var triggerLid = SystemTriggers.shared.triggerOnLidOpened

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "gyroscope",
                tint: Theme.working,
                title: "800 Hz Apple Silicon motion sensor",
                subtitle: "Tap your desk slightly to see the live accelerometer readout below, and choose how sensitive the motion trigger should be."
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live accelerometer displacement").font(.tileTitle)
                        Text("3s grace period (2 beeps—put it down still to cancel), then \(coordinator.countdownDurationSeconds)s Touch ID countdown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.3f g", coordinator.liveDeltaG))
                        .font(.statValue)
                        .foregroundStyle(Theme.workingInk)
                        .contentTransition(.numericText())
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
            .tile()

            VStack(spacing: 12) {
                SwitchRow(
                    title: "Trigger when charger is unplugged",
                    subtitle: "3s grace period (2 beeps—plug power back in to cancel), then \(coordinator.countdownDurationSeconds)s Touch ID countdown before the siren.",
                    isOn: Binding(
                        get: { triggerPower },
                        set: {
                            triggerPower = $0
                            SystemTriggers.shared.triggerOnPowerUnplugged = $0
                        }
                    )
                )
                Divider()
                SwitchRow(
                    title: "Trigger when lid is opened or woken",
                    subtitle: "Gives a \(coordinator.countdownDurationSeconds)s Touch ID grace countdown (gentle beeps) when you open your lid before the siren sounds.",
                    isOn: Binding(
                        get: { triggerLid },
                        set: {
                            triggerLid = $0
                            SystemTriggers.shared.triggerOnLidOpened = $0
                        }
                    )
                )
            }
            .tile()
            .padding(.top, 10)
        }
    }
}

private struct GraceAndCountdownStep: View {
    @ObservedObject private var coordinator = AlarmCoordinator.shared
    @State private var countdownSeconds = AlarmCoordinator.shared.countdownDurationSeconds
    @State private var lockOnTrigger = AlarmCoordinator.shared.lockScreenOnTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "hand.raised.fill",
                tint: Theme.grace,
                title: "Bump-proof 3-second grace period",
                subtitle: "If you nudge the table or lift the laptop slightly, Tjuv plays two short warning beeps. Put the laptop back down still within 3 seconds and the alarm cancels automatically."
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. Motion grace period (3 seconds)").font(.tileTitle)
                        Text("Plays two short warning beeps. Hold still to return to armed mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test 2 Beeps") {
                        AudioController.shared.playGraceWarningDoubleBeep()
                    }
                    .controlSize(.small)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("2. Touch ID countdown if movement continues").font(.tileTitle)
                        Text("Locks screen & plays gentle countdown beeps before the 100% siren.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Countdown", selection: Binding(
                        get: { countdownSeconds },
                        set: {
                            countdownSeconds = $0
                            coordinator.countdownDurationSeconds = $0
                        }
                    )) {
                        Text("3s").tag(3)
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }
            .tile()

            SwitchRow(
                title: "Lock the screen when a trigger escalates",
                subtitle: "Uses SACLockScreenImmediate so a thief never gets an unlocked desktop.",
                isOn: Binding(
                    get: { lockOnTrigger },
                    set: {
                        lockOnTrigger = $0
                        coordinator.lockScreenOnTrigger = $0
                    }
                )
            )
            .tile()
            .padding(.top, 10)
        }
    }
}

private struct LidAndFindMyStep: View {
    @ObservedObject private var sleepManager = SleepManager.shared
    @ObservedObject private var coordinator = AlarmCoordinator.shared
    @State private var lockOnLidClose = AlarmCoordinator.shared.lockScreenOnLidClose
    @State private var findMyStatus = FindMyDetector.currentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "laptopcomputer",
                tint: Theme.lid,
                title: "Close the lid, keep guarding",
                subtitle: "Normally a MacBook sleeps the moment you close it. Tjuv can keep the sensors & Wi-Fi active while armed, and lets it sleep normally as soon as you disarm."
            )

            VStack(alignment: .leading, spacing: 12) {
                SwitchRow(
                    title: "Protect with the lid closed",
                    subtitle: sleepManager.isBusy ? "Waiting for your password…" : "Asks for your admin password once.",
                    isOn: Binding(
                        get: { sleepManager.isBusy || (sleepManager.closedLidProtectionEnabled && sleepManager.isSetUp) },
                        set: { sleepManager.setClosedLidMode($0) }
                    ),
                    tint: Theme.lid
                )
                .disabled(sleepManager.isBusy)

                if sleepManager.closedLidProtectionEnabled && sleepManager.isSetUp && ScreenLocker.isAvailable {
                    Divider()
                    SwitchRow(
                        title: "Lock the screen when the lid closes",
                        subtitle: "Plays a lock chime when closed; unlocking your Mac returns Tjuv to standby automatically.",
                        isOn: Binding(
                            get: { lockOnLidClose },
                            set: {
                                lockOnLidClose = $0
                                coordinator.lockScreenOnLidClose = $0
                            }
                        ),
                        tint: Theme.lid
                    )
                }

                if let error = sleepManager.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            .tile()

            HStack(spacing: 12) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(findMyStatus == .enabled ? Theme.working : Theme.grace)
                VStack(alignment: .leading, spacing: 2) {
                    Text(findMyStatus == .enabled ? "Find My Mac (AirTag Beacon) is Active" : "Find My Mac is Off")
                        .font(.tileTitle)
                    Text("Apple Silicon Macs broadcast encrypted P-224 AirTag beacons to Apple's Find My network even offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if findMyStatus != .enabled {
                    Button("Enable…") {
                        FindMyDetector.openSystemSettings()
                    }
                    .controlSize(.small)
                }
            }
            .tile()
            .padding(.top, 10)
            .onAppear {
                sleepManager.refreshSetupStatus()
                findMyStatus = FindMyDetector.currentStatus
            }
        }
    }
}

private struct DoneStep: View {
    @Binding var launchAtLogin: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                symbol: "checkmark.circle.fill",
                tint: Theme.working,
                title: "You're all set",
                subtitle: "Tjuv lives in your menu bar. Click the thief mask anytime to arm your MacBook, adjust sensitivity, or test the siren."
            )
            SwitchRow(
                title: "Launch at login",
                subtitle: "Start Tjuv automatically in your menu bar when you log in.",
                isOn: $launchAtLogin
            )
            .tile()
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.top, 8)
            }
            Text("You can change all of this later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
    }
}
