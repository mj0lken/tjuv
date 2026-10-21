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
    let version: AppVersion
    let pageURL: URL

    init(version: AppVersion, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }

    static func isTrustedPage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
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
        self.init(version: version, pageURL: page)
    }
}

enum UpdateCheck {
    static let interval: TimeInterval = 24 * 60 * 60

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    static func availableUpdate(current: AppVersion?, latest: LatestRelease?) -> LatestRelease? {
        guard let current, let latest, latest.version > current else { return nil }
        return latest
    }
}

/// Asks GitHub once a day whether a newer release of Tjuv exists.
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastCheck: Date?
    private(set) var availableUpdate: LatestRelease?

    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    let isHomebrewInstall = ["/opt/homebrew/Caskroom/tjuv", "/usr/local/Caskroom/tjuv"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    static let homebrewCommand = "brew upgrade --cask tjuv"

    private static let log = Logger(subsystem: "com.mj0lken.tjuv", category: "updates")
    private static let endpoint = URL(string: "https://api.github.com/repos/mj0lken/tjuv/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"
    private static let latestTagKey = "latestReleaseTag"
    private static let latestPageKey = "latestReleasePage"
    private static let autoCheckKey = "checksForUpdates"

    var checksAutomatically: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.autoCheckKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey)
        }
    }

    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        if let tag = defaults.string(forKey: Self.latestTagKey).flatMap(AppVersion.init),
           let page = defaults.url(forKey: Self.latestPageKey), LatestRelease.isTrustedPage(page) {
            availableUpdate = UpdateCheck.availableUpdate(current: currentVersion, latest: LatestRelease(version: tag, pageURL: page))
        }
    }

    func start() {
        guard timer == nil, currentVersion != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard checksAutomatically, UpdateCheck.isDue(lastCheck: lastCheck, now: Date()) else { return }
        checkNow(completion: nil)
    }

    func checkNow(completion: ((Result<LatestRelease?, Error>) -> Void)?) {
        guard status != .checking else { return }
        guard let currentVersion else {
            let err = NSError(domain: "TjuvUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "This build has no version number to compare."])
            status = .failed(err.localizedDescription)
            completion?(.failure(err))
            return
        }
        status = .checking
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("tjuv/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                    self.status = .failed(error.localizedDescription)
                    completion?(.failure(error))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data else {
                    let msg = "GitHub answered with status \(code)."
                    self.status = .failed(msg)
                    completion?(.failure(NSError(domain: "TjuvUpdate", code: code, userInfo: [NSLocalizedDescriptionKey: msg])))
                    return
                }
                do {
                    let latest = try JSONDecoder().decode(LatestRelease.self, from: data)
                    self.record(latest, at: Date())
                    self.availableUpdate = UpdateCheck.availableUpdate(current: currentVersion, latest: latest)
                    self.status = self.availableUpdate == nil ? .upToDate : .idle
                    completion?(.success(self.availableUpdate))
                } catch {
                    let msg = "GitHub's answer didn't look like a release."
                    self.status = .failed(msg)
                    completion?(.failure(error))
                }
            }
        }.resume()
    }

    private func record(_ latest: LatestRelease, at date: Date) {
        lastCheck = date
        let defaults = UserDefaults.standard
        defaults.set(date, forKey: Self.lastCheckKey)
        defaults.set(latest.version.description, forKey: Self.latestTagKey)
        defaults.set(latest.pageURL, forKey: Self.latestPageKey)
    }
}
