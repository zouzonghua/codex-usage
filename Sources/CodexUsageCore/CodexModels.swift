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
    public let userID: String?

    public init(id: String, email: String, accountID: String? = nil, homePath: String, source: Source, userID: String? = nil) {
        self.id = id
        self.email = email
        self.accountID = accountID
        self.homePath = homePath
        self.source = source
        self.userID = userID
    }

    public var identity: CodexIdentity? {
        CodexIdentity(accountID: self.accountID, userID: self.userID, email: self.email)
    }

    public var cacheKey: String { self.identity?.key ?? "profile:\(self.homePath)" }

    public var displayName: String {
        if !self.email.isEmpty { return self.email }
        return self.source == .system ? "当前 Codex 账号" : URL(fileURLWithPath: self.homePath).lastPathComponent
    }
}

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?
    public let email: String?
    public let userID: String?
    public let expiresAt: Date?
    public let refreshedAt: Date?
    public let isAPIKey: Bool

    public init(
        accessToken: String, accountID: String?, email: String?, userID: String? = nil,
        expiresAt: Date? = nil, isAPIKey: Bool = false, refreshedAt: Date? = nil)
    {
        self.accessToken = accessToken
        self.accountID = accountID
        self.email = email
        self.userID = userID
        self.expiresAt = expiresAt
        self.refreshedAt = refreshedAt
        self.isAPIKey = isAPIKey
    }

    public var identity: CodexIdentity? {
        CodexIdentity(accountID: self.accountID, userID: self.userID, email: self.email)
    }
}

public struct CodexIdentity: Equatable, Sendable {
    public let accountID: String
    public let userID: String?
    public let email: String?

    public init?(accountID: String?, userID: String?, email: String?) {
        guard let accountID, !accountID.isEmpty else { return nil }
        let userID = userID.flatMap { $0.isEmpty ? nil : $0 }
        let email = email.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        guard userID != nil || email != nil else { return nil }
        self.accountID = accountID
        self.userID = userID
        self.email = email
    }

    public var key: String {
        let parts = [self.accountID, self.userID.map { "user:\($0)" } ?? "email:\(self.email ?? "")"]
        return "identity:" + ((try? JSONEncoder().encode(parts)) ?? Data()).base64EncodedString()
    }

    public func matches(_ other: CodexIdentity) -> Bool {
        guard self.accountID == other.accountID else { return false }
        if let userID = self.userID, let otherUserID = other.userID { return userID == otherUserID }
        guard let email = self.email, let otherEmail = other.email else { return false }
        return email == otherEmail
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
    case forbidden
    case unsupportedAuth
    case credentialsChanged
    case identityMismatch
    case currentAccountRemoval
    case accountStorage(String)
    case authenticationUnavailable
    case operationTimedOut
    case loginFailed
    case invalidResponse
    case server(Int)
    case network(String)
    case codexExecutableMissing
    case accountSwitch(String)

    public var errorDescription: String? {
        switch self {
        case .authFileMissing:
            "没有找到此账号的登录凭据，请在管理账号中重新登录。"
        case .invalidAuth:
            "此账号的登录凭据无法解析，请在管理账号中重新登录。"
        case .unauthorized:
            "此账号需要重新登录，请在管理账号中选择重新登录。"
        case .forbidden:
            "额度接口拒绝访问（HTTP 403），请检查账号权限或网络访问限制。"
        case .unsupportedAuth:
            "API Key 登录不支持查询 ChatGPT 订阅额度，请添加 ChatGPT 账号。"
        case .credentialsChanged:
            "账号登录状态已在其他地方更新，请刷新后重试。"
        case .identityMismatch:
            "登录的账号或工作区与原账号不一致，原登录状态已保留。"
        case .currentAccountRemoval:
            "此账号正在被 Codex 使用，请先切换到其他账号再删除。"
        case let .accountStorage(message):
            "账号文件操作失败：\(message)"
        case .authenticationUnavailable:
            "自动续期失败，请检查网络和 Codex CLI 版本后重试，或重新登录此账号。"
        case .operationTimedOut:
            "账号操作超时，请重试。"
        case .loginFailed:
            "账号登录未完成，原登录状态已保留。"
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
