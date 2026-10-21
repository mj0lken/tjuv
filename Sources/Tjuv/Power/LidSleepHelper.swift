import Foundation

/// Commands and files for lid-closed protection mode.
///
/// Closing the lid ignores standard IOKit power assertions; only the root-only `SleepDisabled`
/// switch (`pmset -a disablesleep 1`) prevents lid sleep. A one-time admin prompt installs a
/// `visudo`-validated sudoers rule that allows only two exact commands (`pmset -a disablesleep 0`
/// and `1`), and a dead-man's switch watchdog process restores lid sleep within seconds if Tjuv
/// crashes or is killed.
enum LidSleepHelper {
    static let sudoersPath = "/etc/sudoers.d/tjuv"
    static let pmsetPath = "/usr/bin/pmset"
    static let sudoPath = "/usr/bin/sudo"

    enum SetupError: Error, Equatable, LocalizedError {
        case invalidUserName(String)

        var errorDescription: String? {
            switch self {
            case .invalidUserName(let name):
                return "Invalid macOS short user name: \(name)"
            }
        }
    }

    static func pmsetArguments(disableSleep: Bool) -> [String] {
        ["-a", "disablesleep", disableSleep ? "1" : "0"]
    }

    private static func pmsetCommand(disableSleep: Bool) -> String {
        ([pmsetPath] + pmsetArguments(disableSleep: disableSleep)).joined(separator: " ")
    }

    /// Validates macOS short names so nothing can smuggle sudoers syntax into the rule.
    static func isValidUserName(_ user: String) -> Bool {
        guard let first = user.unicodeScalars.first, first != "-", first != "." else { return false }
        return user.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    static func sudoersContent(user: String) throws -> String {
        guard isValidUserName(user) else { throw SetupError.invalidUserName(user) }
        return """
        # Installed by Tjuv so it can keep the Mac armed with the lid closed.
        # Remove from Tjuv's menu, or: sudo pmset -a disablesleep 0 && sudo rm \(sudoersPath)
        \(user) ALL=(root) NOPASSWD: \(pmsetCommand(disableSleep: false)), \(pmsetCommand(disableSleep: true))

        """
    }

    /// Runs as root. Writes the rule into a root-only staging file (sudo ignores names with a dot),
    /// validates it with `visudo -cf`, sets `root:wheel` `0440` permissions, and atomically moves
    /// it into `/etc/sudoers.d/tjuv`.
    static func installScript(user: String) throws -> String {
        let lines = try sudoersContent(user: user)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map { shellQuote(String($0)) }
            .joined(separator: " ")
        return "umask 077; t=$(/usr/bin/mktemp /private/etc/sudoers.d/.tjuv.XXXXXX) || exit 1; "
            + "/usr/bin/printf '%s\\n' \(lines) > \"$t\" && /usr/sbin/visudo -cf \"$t\" && "
            + "/usr/sbin/chown root:wheel \"$t\" && /bin/chmod 0440 \"$t\" && "
            + "/bin/mv -f \"$t\" \(sudoersPath) || { /bin/rm -f \"$t\"; exit 1; }"
    }

    static func uninstallScript() -> String {
        "\(pmsetCommand(disableSleep: false)); /bin/rm -f \(sudoersPath)"
    }

    /// Dead-man switch: once this exact app process is gone (checked by path so a reused PID
    /// doesn't fool it), turn lid sleep back on, retrying if needed.
    static func watchdogScript(appPID: Int32, executablePath: String) -> String {
        "while [ \"$(/bin/ps -o comm= -p \(appPID))\" = \(shellQuote(executablePath)) ]; do /bin/sleep 5; done; "
            + "n=0; until \(sudoPath) -n \(pmsetCommand(disableSleep: false)); do "
            + "n=$((n+1)); [ \"$n\" -ge 20 ] && exit 1; /bin/sleep 15; done"
    }

    static func administratorAppleScript(shell: String, prompt: String) -> String {
        "do shell script \(appleScriptString(shell)) with prompt \(appleScriptString(prompt)) with administrator privileges"
    }

    private static func appleScriptString(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
