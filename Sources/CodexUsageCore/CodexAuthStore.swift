import Foundation

public final class CodexAccountStore {
    private struct SavedAccount: Codable, Equatable {
        let id: String
        let homePath: String
        let email: String
        let accountID: String?
    }

    public let applicationSupportURL: URL
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        applicationSupportURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
    {
        self.fileManager = fileManager
        self.environment = environment
        self.applicationSupportURL = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexUsage", isDirectory: true)
    }

    public var systemHomeURL: URL {
        if let rawHome = self.environment["CODEX_HOME"],
           !rawHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: rawHome, isDirectory: true)
        }
        return self.fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private var savedAccountsURL: URL {
        self.applicationSupportURL.appendingPathComponent("accounts.json", isDirectory: false)
    }

    private var savedHomesURL: URL {
        self.applicationSupportURL.appendingPathComponent("accounts", isDirectory: true)
    }

    public func loadAccounts() -> [CodexAccount] {
        var accounts: [CodexAccount] = []
        if let system = self.account(id: "system", homeURL: self.systemHomeURL, source: .system) {
            accounts.append(system)
        }
        let systemCredentials = accounts.first.flatMap { try? self.credentials(for: $0) }

        var knownPaths = Set(accounts.map(\.homePath))
        let saved = self.loadSavedAccounts()
        for savedAccount in saved {
            let homeURL = URL(fileURLWithPath: savedAccount.homePath, isDirectory: true)
            if let account = self.account(id: savedAccount.id, homeURL: homeURL, source: .saved),
               knownPaths.insert(account.homePath).inserted,
               !Self.sameIdentity(systemCredentials, try? self.credentials(for: account))
            {
                accounts.append(account)
            }
        }

        if let directories = try? self.fileManager.contentsOfDirectory(
            at: self.savedHomesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for directory in directories where directory.hasDirectoryPath {
                let id = directory.lastPathComponent
                if let account = self.account(id: id, homeURL: directory, source: .saved),
                   knownPaths.insert(account.homePath).inserted,
                   !Self.sameIdentity(systemCredentials, try? self.credentials(for: account))
                {
                    accounts.append(account)
                }
            }
        }

        return accounts
    }

    public func credentials(for account: CodexAccount) throws -> CodexCredentials {
        let url = URL(fileURLWithPath: account.homePath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard self.fileManager.fileExists(atPath: url.path) else {
            throw CodexUsageError.authFileMissing
        }
        do {
            return try Self.parseCredentials(data: Data(contentsOf: url))
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.invalidAuth
        }
    }

    public func createManagedHome() throws -> URL {
        let homeURL = self.savedHomesURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try? self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: homeURL.path)
        return homeURL
    }

    @discardableResult
    public func registerManagedAccount(at homeURL: URL) throws -> CodexAccount {
        let credentials = try Self.parseCredentials(
            data: Data(contentsOf: homeURL.appendingPathComponent("auth.json", isDirectory: false)))
        let id = homeURL.lastPathComponent
        let account = CodexAccount(
            id: id,
            email: credentials.email ?? id,
            accountID: credentials.accountID,
            homePath: homeURL.standardizedFileURL.path,
            source: .saved)
        var saved = self.loadSavedAccounts().filter { $0.id != id && $0.homePath != account.homePath }
        saved.append(SavedAccount(
            id: account.id,
            homePath: account.homePath,
            email: account.email,
            accountID: account.accountID))
        try self.saveSavedAccounts(saved)
        return account
    }

    /// Makes the selected profile the account used by the regular Codex CLI.
    /// The current auth file is first copied into an app-owned profile so switching back is possible.
    public func activate(_ account: CodexAccount) throws {
        guard account.source == .saved else { return }
        let targetURL = URL(fileURLWithPath: account.homePath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        let targetData: Data
        do {
            targetData = try Data(contentsOf: targetURL)
        } catch {
            throw CodexUsageError.accountSwitch("目标账号的 auth.json 无法读取")
        }

        let systemURL = self.systemHomeURL.appendingPathComponent("auth.json", isDirectory: false)
        let currentData = try? Data(contentsOf: systemURL)
        if let currentData, currentData != targetData {
            let currentCredentials = try? Self.parseCredentials(data: currentData)
            let alreadySaved = self.loadSavedAccounts().contains { saved in
                Self.sameIdentity(
                    currentCredentials,
                    Self.credentials(at: URL(fileURLWithPath: saved.homePath, isDirectory: true)))
            }
            if !alreadySaved {
                let backupURL = try self.createManagedHome()
                do {
                    try self.writePrivate(currentData, to: backupURL.appendingPathComponent("auth.json"))
                    _ = try self.registerManagedAccount(at: backupURL)
                } catch {
                    self.removeManagedHome(backupURL)
                    throw CodexUsageError.accountSwitch("当前账号备份失败")
                }
            }
        }

        do {
            try self.fileManager.createDirectory(at: self.systemHomeURL, withIntermediateDirectories: true)
            try self.writePrivate(targetData, to: systemURL)
        } catch {
            throw CodexUsageError.accountSwitch("无法更新当前 Codex auth.json")
        }
    }

    public func removeManagedHome(_ homeURL: URL) {
        try? self.fileManager.removeItem(at: homeURL)
        let path = homeURL.standardizedFileURL.path
        let saved = self.loadSavedAccounts().filter { $0.homePath != path }
        try? self.saveSavedAccounts(saved)
    }

    public static func parseCredentials(data: Data) throws -> CodexCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidAuth
        }

        if let apiKey = Self.nonEmptyString(json["OPENAI_API_KEY"]) {
            return CodexCredentials(accessToken: apiKey, accountID: nil, email: nil)
        }

        let tokens = json["tokens"] as? [String: Any]
        guard let accessToken = Self.nonEmptyString(tokens?["access_token"])
            ?? Self.nonEmptyString(tokens?["accessToken"])
        else {
            throw CodexUsageError.invalidAuth
        }

        let idToken = Self.nonEmptyString(tokens?["id_token"]) ?? Self.nonEmptyString(tokens?["idToken"])
        let claims = Self.jwtClaims(idToken ?? accessToken)
        let authClaims = claims?["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = claims?["https://api.openai.com/profile"] as? [String: Any]
        let email = Self.nonEmptyString(claims?["email"])
            ?? Self.nonEmptyString(profileClaims?["email"])
        let accountID = Self.nonEmptyString(tokens?["account_id"])
            ?? Self.nonEmptyString(tokens?["accountId"])
            ?? Self.nonEmptyString(authClaims?["chatgpt_account_id"])
            ?? Self.nonEmptyString(claims?["chatgpt_account_id"])

        return CodexCredentials(accessToken: accessToken, accountID: accountID, email: email)
    }

    private func account(id: String, homeURL: URL, source: CodexAccount.Source) -> CodexAccount? {
        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL),
              let credentials = try? Self.parseCredentials(data: data)
        else {
            return nil
        }
        return CodexAccount(
            id: id,
            email: credentials.email ?? (source == .system ? "" : id),
            accountID: credentials.accountID,
            homePath: homeURL.standardizedFileURL.path,
            source: source)
    }

    private static func credentials(at homeURL: URL) -> CodexCredentials? {
        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        return try? Self.parseCredentials(data: Data(contentsOf: authURL))
    }

    private static func sameIdentity(_ lhs: CodexCredentials?, _ rhs: CodexCredentials?) -> Bool {
        guard let lhs, let rhs else { return false }
        if let lhsID = lhs.accountID, let rhsID = rhs.accountID {
            return lhsID == rhsID
        }
        guard let lhsEmail = lhs.email?.lowercased(), let rhsEmail = rhs.email?.lowercased() else {
            return false
        }
        return lhsEmail == rhsEmail
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
    }

    private func loadSavedAccounts() -> [SavedAccount] {
        guard let data = try? Data(contentsOf: self.savedAccountsURL) else { return [] }
        return (try? JSONDecoder().decode([SavedAccount].self, from: data)) ?? []
    }

    private func saveSavedAccounts(_ accounts: [SavedAccount]) throws {
        try self.fileManager.createDirectory(at: self.applicationSupportURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(accounts)
        try data.write(to: self.savedAccountsURL, options: .atomic)
        try? self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.savedAccountsURL.path)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
