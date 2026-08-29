import Foundation

public struct CodexAccount: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        case system
        case saved
    }

    public let id: String
    public let email: String
    public let accountID: String?
    public let homePath: String
    public let source: Source

    public init(id: String, email: String, accountID: String? = nil, homePath: String, source: Source) {
        self.id = id
        self.email = email
        self.accountID = accountID
        self.homePath = homePath
        self.source = source
    }

    public var displayName: String {
        if !self.email.isEmpty { return self.email }
        return self.source == .system ? "当前 Codex 账号" : URL(fileURLWithPath: self.homePath).lastPathComponent
    }
}

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let email: String?

    public init(accessToken: String, accountID: String?, email: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.email = email
    }
}

public struct CodexRateWindow: Equatable, Sendable {
    public let usedPercent: Int
    public let resetAt: Date?

    public init(usedPercent: Int, resetAt: Date?) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetAt = resetAt
    }

    public var remainingPercent: Int {
        100 - self.usedPercent
    }
}

public struct CodexResetCreditSummary: Equatable, Sendable {
    public let availableCount: Int
    public let nextExpiry: Date?

    public init(availableCount: Int, nextExpiry: Date?) {
        self.availableCount = max(0, availableCount)
        self.nextExpiry = nextExpiry
    }
}

public struct CodexUsage: Equatable, Sendable {
    public let planType: String?
    public let primary: CodexRateWindow?
    public let secondary: CodexRateWindow?
    public let credits: Double?
    public let resetCredits: CodexResetCreditSummary?
    public let fetchedAt: Date
    public let subscriptionExpiresAt: Date?

    public init(
        planType: String?,
        primary: CodexRateWindow?,
        secondary: CodexRateWindow?,
        credits: Double?,
        resetCredits: CodexResetCreditSummary?,
        fetchedAt: Date = Date(),
        subscriptionExpiresAt: Date? = nil)
    {
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.resetCredits = resetCredits
        self.fetchedAt = fetchedAt
        self.subscriptionExpiresAt = subscriptionExpiresAt
    }
}

public enum CodexUsageError: Error, Equatable, LocalizedError, Sendable {
    case authFileMissing
    case invalidAuth
    case unauthorized
    case invalidResponse
    case server(Int)
    case network(String)
    case codexExecutableMissing
    case accountSwitch(String)

    public var errorDescription: String? {
        switch self {
        case .authFileMissing:
            "没有找到 auth.json，请先运行 codex login。"
        case .invalidAuth:
            "auth.json 无法解析，请重新运行 codex login。"
        case .unauthorized:
            "Codex 登录状态已失效，请重新运行 codex login。"
        case .invalidResponse:
            "Codex 返回的数据格式无法识别。"
        case let .server(statusCode):
            "Codex 服务返回错误（HTTP \(statusCode)）。"
        case let .network(message):
            "网络请求失败：\(message)"
        case .codexExecutableMissing:
            "没有找到 codex 命令，请先安装 Codex CLI。"
        case let .accountSwitch(message):
            "切换账号失败：\(message)"
        }
    }
}
