import AppKit
import Foundation

/// Redacts the user's home folder (`~`), account name (`<user>`), and host name (`<host>`)
/// before diagnostics are placed into a GitHub issue link.
struct PrivacyRedactor: Sendable {
    static let userPlaceholder = "<user>"
    static let hostPlaceholder = "<host>"

    private let replacements: [(target: String, replacement: String)]

    init(
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        fullName: String = NSFullUserName(),
        hostName: String = ProcessInfo.processInfo.hostName
    ) {
        let shortHostName = hostName.hasSuffix(".local") ? String(hostName.dropLast(".local".count)) : hostName
        replacements = [
            (homeDirectory, "~"),
            (hostName, Self.hostPlaceholder),
            (shortHostName, Self.hostPlaceholder),
            (fullName, Self.userPlaceholder),
            (userName, Self.userPlaceholder),
        ]
    }

    func redact(_ text: String) -> String {
        replacements.reduce(text) { result, pair in
            Self.replacingWord(pair.target, with: pair.replacement, in: result)
        }
    }

    private static func replacingWord(_ target: String, with replacement: String, in text: String) -> String {
        guard !target.isEmpty, target != "/" else { return text }
        let start = target.hasPrefix("/") ? "" : #"(?<!\w)"#
        let pattern = start + NSRegularExpression.escapedPattern(for: target) + #"(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}

/// Builds a pre-filled GitHub issue URL for `mj0lken/tjuv` with redacted hardware & app diagnostics.
enum GitHubIssueLink {
    static let repository = "mj0lken/tjuv"
    static let maxLength = 7_500

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func url(title: String, body: String) -> URL {
        let query = [("title", title), ("body", body), ("labels", "bug")]
            .map { name, value in "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return URL(string: "https://github.com/\(repository)/issues/new?\(query)")!
    }

    static func buildDiagnosticBody(redactor: PrivacyRedactor = PrivacyRedactor()) -> String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let speakerFound = AudioController.shared.findBuiltInSpeakerID() != nil ? "yes" : "no"
        let imuAvailable = MotionDetector.shared.isHardwareAvailable ? "yes (AppleSPUHIDDevice)" : "no"
        let sudoers = SleepManager.shared.hasPasswordlessSudo ? "installed" : "not set up"
        let sleepDisabled = SleepManager.shared.isSystemSleepCurrentlyDisabled ? "1" : "0"
        let findMy = FindMyDetector.currentStatus.shortSummary
        let screenLock = ScreenLocker.isAvailable ? "available" : "unavailable"
        let loginItem = LaunchAtLogin.statusDescription

        let lines = [
            "### What happened",
            "",
            "<!-- What did you see, and what did you expect? Steps to reproduce help. -->",
            "",
            "### Tjuv & This Mac",
            "",
            "- **Tjuv:** \(version) (build \(build))",
            "- **macOS:** \(redactor.redact(osVersion))",
            "- **Apple Silicon IMU:** \(imuAvailable)",
            "- **Built-in speaker:** \(speakerFound)",
            "- **Power:** \(redactor.redact(SystemTriggers.shared.powerStatusSummary))",
            "- **Find My Mac (AirTag beacon):** \(findMy)",
            "",
            "### Protection & Permissions",
            "",
            "- **Lid-closed sudoers rule:** \(sudoers)",
            "- **SleepDisabled right now:** \(sleepDisabled) (by Tjuv: \(SleepManager.shared.isDisabledByUs ? "yes" : "no"))",
            "- **Screen lock (SACLockScreenImmediate):** \(screenLock)",
            "- **Motion sensitivity:** \(MotionDetector.shared.sensitivity.rawValue)",
            "- **Launch at login:** \(loginItem)",
            "",
            "<sub>Added by Tjuv › Report a Bug: only its own version, hardware checks and settings. Your home folder shows as ~ and your user name as &lt;user&gt;.</sub>",
        ]
        return lines.joined(separator: "\n")
    }

    static func openNewIssue() {
        let body = buildDiagnosticBody()
        let link = url(title: "Bug report", body: body)
        NSWorkspace.shared.open(link)
    }
}
