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

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    struct Version: Comparable, Equatable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int
        let isPrerelease: Bool

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") || value.hasPrefix("V") {
                value.removeFirst()
            }
            let parts = value.split(separator: "-", maxSplits: 1)
            let core = parts.first.map(String.init) ?? value
            let components = core.split(separator: ".")
            guard components.count == 3,
                  let major = Int(components[0]),
                  let minor = Int(components[1]),
                  let patch = Int(components[2])
            else { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
            self.isPrerelease = parts.count > 1
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            return lhs.isPrerelease && !rhs.isPrerelease
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
              let url = URL(string: "https://api.github.com/repos/\(self.repository)/releases/latest")
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

            let release: ReleaseResponse
            do {
                release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
            } catch {
                throw CodexUpdateError.invalidResponse
            }
            guard let latest = Version(release.tagName),
                  let releaseURL = URL(string: release.htmlURL),
                  releaseURL.scheme?.lowercased() == "https",
                  releaseURL.host?.lowercased() == "github.com"
            else { throw CodexUpdateError.invalidResponse }
            return CodexUpdateInfo(
                latestVersion: release.tagName,
                releaseURL: releaseURL,
                isUpdateAvailable: current < latest)
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
