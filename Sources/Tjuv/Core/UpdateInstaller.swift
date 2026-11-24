import AppKit
import CryptoKit
import Foundation
import os

/// Downloads a release zip, checks it, and swaps it in for the running app, then relaunches.
///
/// The swap is done by a small detached shell script that waits for this process to exit, so the
/// app never replaces its own bundle while running. The old bundle is kept until the new one is in
/// place, and restored if the move fails.
@MainActor
final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double?)
        case verifying
        case restarting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .restarting: return true
        case .idle, .failed: return false
        }
    }

    private nonisolated static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "updates")
    private nonisolated static let bundleID = "com.mj0lken.tjuv"
    private var progressObservation: NSKeyValueObservation?

    /// Pure policy helper: any writable `Tjuv.app` bundle (including Homebrew's
    /// `/Applications/Tjuv.app`, paired with `auto_updates true` in the cask) can self-update.
    nonisolated static func canSelfUpdate(
        bundleURL: URL,
        bundleIdentifier: String?,
        isWritable: Bool,
        isHomebrewInstall: Bool
    ) -> Bool {
        _ = isHomebrewInstall
        return bundleURL.pathExtension == "app" && bundleIdentifier == bundleID && isWritable
    }

    /// Whether this running copy of the app can update itself in place without asking for a password.
    static func canSelfUpdate(isHomebrewInstall: Bool = false) -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let fm = FileManager.default
        let isWritable = fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: bundleURL.path)
        return canSelfUpdate(
            bundleURL: bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isWritable: isWritable,
            isHomebrewInstall: isHomebrewInstall
        )
    }

    /// Parses a `shasum -a 256` sidecar file (e.g. `<64-hex>  tjuv-1.2.0-arm64.zip`) into a
    /// normalized lowercase 64-character SHA-256 hex digest.
    nonisolated static func parseChecksumFile(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = first.lowercased()
        return UpdateCheck.isValidSHA256(hex) ? hex : nil
    }

    /// Alarm states where quitting the app for a moment doesn't drop protection.
    nonisolated static func isSafeToRestart(_ state: AlarmState) -> Bool {
        switch state {
        case .disarmed, .standby: return true
        default: return false
        }
    }

    /// Clears a previous failure message before retrying or running a fresh update check.
    func resetError() {
        if case .failed = phase {
            phase = .idle
        }
    }

    /// Surfaces a pre-install failure (such as a failed release refresh) in the installer UI.
    func reportFailure(_ message: String) {
        guard !isBusy else { return }
        phase = .failed(message)
    }

    /// Installs the release directly if its asset metadata is already loaded, or refreshes
    /// from GitHub first and surfaces any network error cleanly.
    func installOrRefresh(_ release: LatestRelease) {
        guard !isBusy else { return }
        resetError()
        guard Self.isSafeToRestart(AlarmCoordinator.shared.state) else {
            phase = .failed("Turn the alarm off before updating.")
            return
        }
        if release.asset != nil {
            install(release)
            return
        }
        UpdateChecker.shared.checkNow { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fresh?):
                self.install(fresh)
            case .success(nil):
                self.resetError()
            case .failure(let error):
                self.reportFailure(error.localizedDescription)
            }
        }
    }

    func install(_ release: LatestRelease) {
        guard !isBusy else { return }
        resetError()
        guard Self.isSafeToRestart(AlarmCoordinator.shared.state) else {
            phase = .failed("Turn the alarm off before updating.")
            return
        }
        guard let asset = release.asset else {
            phase = .failed("This release has no app download.")
            return
        }
        phase = .downloading(fraction: nil)
        Task {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tjuv-update-\(UUID().uuidString)", isDirectory: true)
            do {
                let appURL = try await prepare(asset: asset, expected: release.version, workDir: workDir)
                guard Self.isSafeToRestart(AlarmCoordinator.shared.state) else {
                    throw Self.error("Turn the alarm off before updating.")
                }
                phase = .restarting
                try relaunch(into: appURL)
            } catch {
                progressObservation = nil
                try? FileManager.default.removeItem(at: workDir)
                Self.log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Steps

    private func prepare(asset: LatestRelease.Asset, expected: AppVersion, workDir: URL) async throws -> URL {
        let expectedSHA = try await resolveChecksum(for: asset)

        let zipURL = try await download(asset.downloadURL, into: workDir)
        phase = .verifying

        return try await Task.detached(priority: .userInitiated) {
            try Self.verifyAndUnpack(zipURL: zipURL, workDir: workDir, expectedSHA: expectedSHA, expectedVersion: expected)
        }.value
    }

    private nonisolated static func verifyAndUnpack(
        zipURL: URL,
        workDir: URL,
        expectedSHA: String,
        expectedVersion: AppVersion
    ) throws -> URL {
        let actualSHA = try sha256(of: zipURL)
        guard actualSHA == expectedSHA else {
            throw error("The download didn't match its checksum.")
        }

        let unpackDir = workDir.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpackDir.path])

        let appURL = unpackDir.appendingPathComponent("Tjuv.app", isDirectory: true)
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleID,
              let versionText = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              AppVersion(versionText) == expectedVersion,
              FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/Tjuv").path)
        else {
            throw error("The downloaded app isn't the expected Tjuv \(expectedVersion).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        // We downloaded it ourselves, but strip quarantine in case anything added it.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
        return appURL
    }

    private func resolveChecksum(for asset: LatestRelease.Asset) async throws -> String {
        if let sha = asset.sha256 { return sha }
        guard let checksumURL = asset.checksumURL else {
            throw Self.error("The release has no checksum to verify the download with.")
        }
        let (data, response) = try await URLSession.shared.data(from: checksumURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let hex = Self.parseChecksumFile(text)
        else { throw Self.error("Couldn't read the release checksum.") }
        return hex
    }

    private func download(_ url: URL, into workDir: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let location else {
                    return continuation.resume(throwing: Self.error("The download failed."))
                }
                // The file at `location` is deleted when this handler returns, so move it now.
                let kept = workDir.appendingPathComponent("download.zip")
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction: fraction)
                }
            }
            task.resume()
        }
        progressObservation = nil
        return tempURL
    }

    private func relaunch(into newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let script = """
        #!/bin/bash
        # Swaps in the new Tjuv.app once the running one has quit, then opens it.
        trap '' HUP
        PID="$1"; NEW="$2"; TARGET="$3"; BACKUP="$TARGET.previous"
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$PID" 2>/dev/null && exit 1
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP" && /usr/bin/ditto "$NEW" "$TARGET"; then
          rm -rf "$BACKUP"
        else
          rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
        fi
        /usr/bin/open "$TARGET"
        rm -rf "$(dirname "$(dirname "$NEW")")"
        """
        let scriptURL = newApp.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/bash", scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        Self.log.info("Installing update and relaunching")
        // Normal quit: applicationWillTerminate restores sleep and volume settings.
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let toolName = (tool as NSString).lastPathComponent
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stderrText.isEmpty {
                log.error("\(toolName, privacy: .public) failed (\(process.terminationStatus)): \(stderrText, privacy: .public)")
            } else {
                log.error("\(toolName, privacy: .public) failed (\(process.terminationStatus))")
            }
            throw error("\(toolName) failed (\(process.terminationStatus)).")
        }
    }

    private nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "TjuvUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
