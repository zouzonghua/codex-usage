import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexUpdateInfo: Equatable, Sendable {
    public let latestVersion: String
    public let releaseURL: URL
    public let isUpdateAvailable: Bool

    public init(latestVersion: String, releaseURL: URL, isUpdateAvailable: Bool) {
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
        self.isUpdateAvailable = isUpdateAvailable
    }
}

public enum CodexUpdateError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case invalidVersion
    case server(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "更新信息格式无法识别。"
        case .invalidVersion:
            "当前版本号无法识别。"
        case let .server(statusCode):
            "更新服务返回错误（HTTP \(statusCode)）。"
        case let .network(message):
            "检查更新失败：\(message)"
        }
    }
}

public struct CodexUpdateChecker: Sendable {
    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
        }
    }

    struct Version: Comparable, Equatable, Sendable {
        private enum Identifier: Equatable, Sendable {
            case numeric(Int)
            case text(String)
        }

        let major: Int
        let minor: Int
        let patch: Int
        private let prerelease: [Identifier]

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") || value.hasPrefix("V") {
                value.removeFirst()
            }
            let withoutBuild = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
            let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = parts.first.map(String.init) ?? value
            let components = core.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3,
                  let major = Int(components[0]),
                  let minor = Int(components[1]),
                  let patch = Int(components[2])
            else { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
            if parts.count == 1 {
                self.prerelease = []
            } else {
                let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
                guard !identifiers.isEmpty,
                      !identifiers.contains(where: \.isEmpty)
                else { return nil }
                self.prerelease = identifiers.map { identifier in
                    let value = String(identifier)
                    if identifier.allSatisfy(\.isNumber), let number = Int(value) {
                        return .numeric(number)
                    }
                    return .text(value)
                }
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
            case (true, true):
                return false
            case (true, false):
                return false
            case (false, true):
                return true
            case (false, false):
                for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
                    guard left != right else { continue }
                    switch (left, right) {
                    case let (.numeric(left), .numeric(right)):
                        return left < right
                    case (.numeric, .text):
                        return true
                    case (.text, .numeric):
                        return false
                    case let (.text(left), .text(right)):
                        return left < right
                    }
                }
                return lhs.prerelease.count < rhs.prerelease.count
            }
        }
    }

    private let session: URLSession
    private let repository: String

    public init(
        repository: String = "zouzonghua/codex-usage",
        session: URLSession = .shared)
    {
        self.repository = repository
        self.session = session
    }

    public func check(currentVersion: String) async throws -> CodexUpdateInfo {
        guard let current = Version(currentVersion),
              let url = URL(string: "https://api.github.com/repos/\(self.repository)/releases?per_page=100")
        else { throw CodexUpdateError.invalidVersion }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsage", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexUpdateError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw CodexUpdateError.server(httpResponse.statusCode)
            }

            let releases: [ReleaseResponse]
            do {
                releases = try JSONDecoder().decode([ReleaseResponse].self, from: data)
            } catch {
                throw CodexUpdateError.invalidResponse
            }

            var latestRelease: (release: ReleaseResponse, version: Version)?
            for release in releases where release.draft != true {
                guard let version = Version(release.tagName) else { continue }
                if latestRelease == nil || latestRelease!.version < version {
                    latestRelease = (release, version)
                }
            }
            guard let latestRelease,
                  let releaseURL = URL(string: latestRelease.release.htmlURL),
                  releaseURL.scheme?.lowercased() == "https",
                  releaseURL.host?.lowercased() == "github.com"
            else { throw CodexUpdateError.invalidResponse }
            return CodexUpdateInfo(
                latestVersion: latestRelease.release.tagName,
                releaseURL: releaseURL,
                isUpdateAvailable: current < latestRelease.version)
        } catch let error as CodexUpdateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CodexUpdateError.network(error.localizedDescription)
        }
    }
}
