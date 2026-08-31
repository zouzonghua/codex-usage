import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexUsageClient: Sendable {
    struct UsageResponse: Decodable {
        let planType: String?
        let rateLimit: RateLimitResponse?
        let credits: CreditResponse?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case credits
        }
    }

    struct SubscriptionResponse: Decodable {
        let activeUntil: FlexibleDate?

        enum CodingKeys: String, CodingKey {
            case activeUntil = "active_until"
        }
    }

    struct RateLimitResponse: Decodable {
        let primaryWindow: WindowResponse?
        let secondaryWindow: WindowResponse?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct WindowResponse: Decodable {
        let usedPercent: FlexibleInt?
        let resetAt: FlexibleInt?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
        }
    }

    struct CreditResponse: Decodable {
        let balance: FlexibleDouble?
    }

    struct ResetResponse: Decodable {
        let credits: [ResetCreditResponse]
        let availableCount: FlexibleInt?

        enum CodingKeys: String, CodingKey {
            case credits
            case availableCount = "available_count"
        }
    }

    struct ResetCreditResponse: Decodable {
        let status: String?
        let expiresAt: FlexibleDate?

        enum CodingKeys: String, CodingKey {
            case status
            case expiresAt = "expires_at"
        }
    }

    struct FlexibleInt: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self.value = value
            } else if let value = try? container.decode(Double.self) {
                self.value = Int(value)
            } else if let value = try? container.decode(String.self), let parsed = Int(value) {
                self.value = parsed
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an integer")
            }
        }
    }

    struct FlexibleDouble: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self.value = value
            } else if let value = try? container.decode(String.self), let parsed = Double(value) {
                self.value = parsed
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a number")
            }
        }
    }

    struct FlexibleDate: Decodable {
        let value: Date

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let raw = try? container.decode(String.self) {
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = standard.date(from: raw) ?? fractional.date(from: raw) {
                    self.value = date
                    return
                }
            } else if let seconds = try? container.decode(Double.self) {
                self.value = Date(timeIntervalSince1970: seconds)
                return
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date")
        }
    }

    private let session: URLSession
    private let baseURLOverride: URL?

    public init(session: URLSession = .shared, baseURL: URL? = nil) {
        self.session = session
        self.baseURLOverride = baseURL
    }

    public func fetchUsage(credentials: CodexCredentials, homePath: String) async throws -> CodexUsage {
        let baseURL = self.baseURLOverride ?? Self.resolveBaseURL(homePath: homePath)
        let usagePath = baseURL.path.contains("/backend-api") ? "wham/usage" : "api/codex/usage"
        let usageData = try await self.request(
            url: baseURL.appendingPathComponent(usagePath),
            credentials: credentials,
            timeout: 20)
        let usage = try Self.decodeUsageResponse(data: usageData)

        return CodexUsage(
            planType: usage.planType,
            primary: Self.window(from: usage.rateLimit?.primaryWindow),
            secondary: Self.window(from: usage.rateLimit?.secondaryWindow),
            credits: usage.credits?.balance?.value,
            resetCredits: nil)
    }

    public func fetchResetCredits(
        credentials: CodexCredentials,
        homePath: String) async throws -> CodexResetCreditSummary
    {
        let baseURL = self.baseURLOverride ?? Self.resolveBaseURL(homePath: homePath)
        let resetData = try await self.request(
            url: baseURL.appendingPathComponent("wham/rate-limit-reset-credits"),
            credentials: credentials,
            timeout: 8)
        return try Self.decodeResetCredits(data: resetData)
    }

    public func fetchSubscriptionExpiry(credentials: CodexCredentials, homePath: String) async throws -> Date {
        guard let accountID = credentials.accountID, !accountID.isEmpty else {
            throw CodexUsageError.invalidAuth
        }
        let baseURL = self.baseURLOverride ?? Self.resolveBaseURL(homePath: homePath)
        let subscriptionData = try await self.request(
            url: Self.subscriptionURL(baseURL: baseURL, accountID: accountID),
            credentials: credentials,
            timeout: 8)
        guard let expiresAt = try Self.decodeSubscription(data: subscriptionData).activeUntil?.value else {
            throw CodexUsageError.invalidResponse
        }
        return expiresAt
    }

    static func decodeUsageResponse(data: Data) throws -> UsageResponse {
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw CodexUsageError.invalidResponse
        }
    }

    static func decodeResetCredits(data: Data) throws -> CodexResetCreditSummary {
        do {
            let response = try JSONDecoder().decode(ResetResponse.self, from: data)
            let available = response.credits.filter { $0.status == "available" }
            let nextExpiry = available.compactMap(\.expiresAt?.value).min()
            let count = max(response.availableCount?.value ?? 0, available.count)
            return CodexResetCreditSummary(availableCount: count, nextExpiry: nextExpiry)
        } catch {
            throw CodexUsageError.invalidResponse
        }
    }

    static func decodeSubscription(data: Data) throws -> SubscriptionResponse {
        do {
            return try JSONDecoder().decode(SubscriptionResponse.self, from: data)
        } catch {
            throw CodexUsageError.invalidResponse
        }
    }

    private static func subscriptionURL(baseURL: URL, accountID: String) -> URL {
        let url = baseURL.appendingPathComponent("subscriptions")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
        return components?.url ?? url
    }

    static func resolveBaseURL(homePath: String) -> URL {
        let configURL = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        let configuredURL = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap(Self.chatGPTBaseURL(in:))
        let raw = configuredURL ?? "https://chatgpt.com/backend-api"
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if (normalized.hasPrefix("https://chatgpt.com") || normalized.hasPrefix("https://chat.openai.com")),
           !normalized.contains("/backend-api")
        {
            normalized += "/backend-api"
        }
        return URL(string: normalized) ?? URL(string: "https://chatgpt.com/backend-api")!
    }

    static func chatGPTBaseURL(in contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let withoutComment = line.split(separator: "#", maxSplits: 1).first ?? ""
            let parts = withoutComment.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url"
            else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private func request(url: URL, credentials: CodexCredentials, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexUsage", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexUsageError.invalidResponse
            }
            switch httpResponse.statusCode {
            case 200...299:
                return data
            case 401, 403:
                throw CodexUsageError.unauthorized
            default:
                throw CodexUsageError.server(httpResponse.statusCode)
            }
        } catch let error as CodexUsageError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CodexUsageError.network(error.localizedDescription)
        }
    }

    private static func window(from response: WindowResponse?) -> CodexRateWindow? {
        guard let response,
              response.usedPercent != nil || response.resetAt != nil
        else { return nil }
        let resetAt = response.resetAt.map { rawValue -> Date in
            var seconds = TimeInterval(rawValue.value)
            if seconds > 100_000_000_000 { seconds /= 1_000 }
            return Date(timeIntervalSince1970: seconds)
        }
        return CodexRateWindow(usedPercent: response.usedPercent?.value ?? 0, resetAt: resetAt)
    }

}
