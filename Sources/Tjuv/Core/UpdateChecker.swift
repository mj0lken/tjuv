import Foundation
import os

/// A release version like 1.2.0, compared part by part as numbers, so 1.10.0 is newer than 1.9.0.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// The latest published release, read from GitHub's `releases/latest` API.
struct LatestRelease: Sendable, Equatable, Decodable {
    /// The downloadable app zip attached to the release, with the SHA-256 GitHub reports for it.
    struct Asset: Sendable, Equatable {
        let downloadURL: URL
        let sha256: String?
        /// A separate `<zip>.sha256` asset, used when GitHub reports no digest.
        let checksumURL: URL?
    }

    let version: AppVersion
    let pageURL: URL
    let asset: Asset?

    init(version: AppVersion, pageURL: URL, asset: Asset? = nil) {
        self.version = version
        self.pageURL = pageURL
        self.asset = asset
    }

    static func isTrustedPage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
    }

    static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/mj0lken/tjuv/releases/download/")
    }

    /// Picks the arm64 app zip and its checksum from a release's asset list.
    static func pickAsset(from assets: [RawAsset]) -> Asset? {
        guard let zip = assets.first(where: { $0.name.hasPrefix("tjuv-") && $0.name.hasSuffix("-arm64.zip") }),
              isTrustedDownload(zip.browserDownloadURL) else { return nil }
        var sha: String?
        if let digest = zip.digest, digest.hasPrefix("sha256:") {
            let hex = String(digest.dropFirst("sha256:".count)).lowercased()
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { sha = hex }
        }
        let checksum = assets.first(where: { $0.name == zip.name + ".sha256" })?.browserDownloadURL
        return Asset(downloadURL: zip.browserDownloadURL, sha256: sha,
                     checksumURL: checksum.flatMap { isTrustedDownload($0) ? $0 : nil })
    }

    struct RawAsset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        private enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tagName)
        guard let version = AppVersion(tag) else {
            throw DecodingError.dataCorruptedError(forKey: .tagName, in: container, debugDescription: "Not a version: \(tag)")
        }
        let page = try container.decode(URL.self, forKey: .htmlURL)
        guard Self.isTrustedPage(page) else {
            throw DecodingError.dataCorruptedError(forKey: .htmlURL, in: container, debugDescription: "Not a GitHub page: \(page)")
        }
        let assets = (try? container.decodeIfPresent([RawAsset].self, forKey: .assets)) ?? []
        self.init(version: version, pageURL: page, asset: Self.pickAsset(from: assets))
    }
}

enum UpdateCheck {
    static let interval: TimeInterval = 30 * 60

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    static func availableUpdate(current: AppVersion?, latest: LatestRelease?) -> LatestRelease? {
        guard let current, let latest, latest.version > current else { return nil }
        return latest
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// Detects whether the running app bundle is managed by Homebrew Cask rather than matching
    /// any leftover Caskroom directory on disk (e.g. when running a local `build/Tjuv.app`).
    static func detectHomebrewInstall(
        bundleURL: URL,
        caskroomPaths: [String] = ["/opt/homebrew/Caskroom/tjuv", "/usr/local/Caskroom/tjuv"],
        fileManager: FileManager = .default
    ) -> Bool {
        let standardized = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.pathExtension == "app" else { return false }

        let standardApplications = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        let isInApplicationsDir = standardApplications.contains { appDir in
            standardized.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: appDir).standardizedFileURL.path
        }

        for caskroom in caskroomPaths {
            let caskroomURL = URL(fileURLWithPath: caskroom).standardizedFileURL
            guard fileManager.fileExists(atPath: caskroomURL.path) else { continue }

            // Direct launch from inside Caskroom
            if standardized.path.hasPrefix(caskroomURL.path + "/") {
                return true
            }

            // Standard Homebrew cask moves Tjuv.app to /Applications and keeps Caskroom metadata
            if isInApplicationsDir {
                let metadataPath = caskroomURL.appendingPathComponent(".metadata").path
                if fileManager.fileExists(atPath: metadataPath) {
                    return true
                }
                if let entries = try? fileManager.contentsOfDirectory(at: caskroomURL, includingPropertiesForKeys: nil) {
                    for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                        let candidate = entry.appendingPathComponent(standardized.lastPathComponent)
                        if fileManager.fileExists(atPath: candidate.path),
                           candidate.resolvingSymlinksInPath().standardizedFileURL == standardized {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }
}

/// Checks GitHub releases every 30 minutes (and on activation/wake) using conditional ETag requests.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed(String)
    }

    typealias FetchHandler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?
    @Published private(set) var availableUpdate: LatestRelease?

    let currentVersion: AppVersion?
    let isHomebrewInstall: Bool

    static let homebrewCommand = "brew upgrade --cask tjuv"

    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "updates")
    private static let endpoint = URL(string: "https://api.github.com/repos/mj0lken/tjuv/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"
    private static let latestTagKey = "latestReleaseTag"
    private static let latestPageKey = "latestReleasePage"
    private static let latestAssetURLKey = "latestReleaseAssetURL"
    private static let latestSHA256Key = "latestReleaseSHA256"
    private static let latestChecksumURLKey = "latestReleaseChecksumURL"
    private static let lastETagKey = "lastReleaseETag"
    private static let autoCheckKey = "checksForUpdates"

    private let defaults: UserDefaults
    private let fetch: FetchHandler
    private var cachedLatest: LatestRelease?
    private var timer: Timer?

    var checksAutomatically: Bool {
        get {
            if defaults.object(forKey: Self.autoCheckKey) == nil { return true }
            return defaults.bool(forKey: Self.autoCheckKey)
        }
        set {
            defaults.set(newValue, forKey: Self.autoCheckKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        currentVersion: AppVersion? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
        isHomebrewInstall: Bool = UpdateCheck.detectHomebrewInstall(bundleURL: Bundle.main.bundleURL),
        fetch: @escaping FetchHandler = { try await URLSession.shared.data(for: $0) }
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.isHomebrewInstall = isHomebrewInstall
        self.fetch = fetch

        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        if let tag = defaults.string(forKey: Self.latestTagKey).flatMap(AppVersion.init),
           let page = defaults.url(forKey: Self.latestPageKey), LatestRelease.isTrustedPage(page) {
            let asset: LatestRelease.Asset?
            if let assetURL = defaults.url(forKey: Self.latestAssetURLKey),
               LatestRelease.isTrustedDownload(assetURL) {
                let rawSHA = defaults.string(forKey: Self.latestSHA256Key)?.lowercased()
                let sha = rawSHA.flatMap { UpdateCheck.isValidSHA256($0) ? $0 : nil }
                let checksumURL = defaults.url(forKey: Self.latestChecksumURLKey)
                    .flatMap { LatestRelease.isTrustedDownload($0) ? $0 : nil }
                asset = LatestRelease.Asset(downloadURL: assetURL, sha256: sha, checksumURL: checksumURL)
            } else {
                asset = nil
            }
            let cached = LatestRelease(version: tag, pageURL: page, asset: asset)
            cachedLatest = cached
            availableUpdate = UpdateCheck.availableUpdate(current: currentVersion, latest: cached)
        }
    }

    func start() {
        guard timer == nil, currentVersion != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIfDue()
            }
        }
    }

    func checkIfDue(now: Date = Date()) {
        guard checksAutomatically, UpdateCheck.isDue(lastCheck: lastCheck, now: now) else { return }
        checkNow(completion: nil)
    }

    func checkNow(completion: ((Result<LatestRelease?, Error>) -> Void)? = nil) {
        guard status != .checking else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.performCheck()
            completion?(result)
        }
    }

    @discardableResult
    func performCheck(now: Date = Date()) async -> Result<LatestRelease?, Error> {
        guard status != .checking else {
            return .success(availableUpdate)
        }
        guard let currentVersion else {
            let err = NSError(domain: "TjuvUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "This build has no version number to compare."])
            status = .failed(err.localizedDescription)
            return .failure(err)
        }

        status = .checking
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("tjuv/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        // Send ETag only when our cached release already has complete asset metadata (or matches currentVersion).
        let canUseETag = cachedLatest != nil && (availableUpdate == nil || availableUpdate?.asset != nil)
        if canUseETag, let etag = defaults.string(forKey: Self.lastETagKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await fetch(request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0

            if code == 304 {
                lastCheck = now
                defaults.set(now, forKey: Self.lastCheckKey)
                availableUpdate = UpdateCheck.availableUpdate(current: currentVersion, latest: cachedLatest)
                status = availableUpdate == nil ? .upToDate : .idle
                return .success(availableUpdate)
            }

            guard code == 200 else {
                let msg = "GitHub answered with status \(code)."
                status = .failed(msg)
                return .failure(NSError(domain: "TjuvUpdate", code: code, userInfo: [NSLocalizedDescriptionKey: msg]))
            }

            do {
                let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
                let etag = http?.value(forHTTPHeaderField: "ETag")
                record(latest, etag: etag, at: now)
                cachedLatest = latest
                availableUpdate = UpdateCheck.availableUpdate(current: currentVersion, latest: latest)
                status = availableUpdate == nil ? .upToDate : .idle
                return .success(availableUpdate)
            } catch {
                let msg = "GitHub's answer didn't look like a release."
                status = .failed(msg)
                return .failure(error)
            }
        } catch {
            Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            return .failure(error)
        }
    }

    private func record(_ latest: LatestRelease, etag: String?, at date: Date) {
        lastCheck = date
        defaults.set(date, forKey: Self.lastCheckKey)
        defaults.set(latest.version.description, forKey: Self.latestTagKey)
        defaults.set(latest.pageURL, forKey: Self.latestPageKey)

        if let asset = latest.asset {
            defaults.set(asset.downloadURL, forKey: Self.latestAssetURLKey)
            if let sha = asset.sha256 {
                defaults.set(sha, forKey: Self.latestSHA256Key)
            } else {
                defaults.removeObject(forKey: Self.latestSHA256Key)
            }
            if let checksumURL = asset.checksumURL {
                defaults.set(checksumURL, forKey: Self.latestChecksumURLKey)
            } else {
                defaults.removeObject(forKey: Self.latestChecksumURLKey)
            }
        } else {
            defaults.removeObject(forKey: Self.latestAssetURLKey)
            defaults.removeObject(forKey: Self.latestSHA256Key)
            defaults.removeObject(forKey: Self.latestChecksumURLKey)
        }

        if let etag, !etag.isEmpty {
            defaults.set(etag, forKey: Self.lastETagKey)
        }
    }
}
