import Foundation

public final class CodexAccountStore {
    private struct SavedAccount: Codable, Equatable {
        let id: String
        let homePath: String
        let email: String
        let accountID: String?
        let userID: String?
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
        for account in self.managedAccounts() {
            if !accounts.contains(where: { Self.sameIdentity($0.identity, account.identity) }) {
                accounts.append(account)
            }
        }
        return accounts
    }

    public func managedAccounts() -> [CodexAccount] {
        var accounts: [CodexAccount] = []
        var knownPaths: Set<String> = []
        for saved in self.loadSavedAccounts() {
            let homeURL = URL(fileURLWithPath: saved.homePath, isDirectory: true)
            guard (try? self.validateManagedHome(homeURL)) != nil,
                  knownPaths.insert(homeURL.standardizedFileURL.path).inserted else { continue }
            accounts.append(self.account(id: saved.id, homeURL: homeURL, source: .saved)
                ?? CodexAccount(id: saved.id, email: saved.email, accountID: saved.accountID,
                                homePath: homeURL.path, source: .saved, userID: saved.userID))
        }
        let directories = (try? self.fileManager.contentsOfDirectory(
            at: self.savedHomesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for directory in directories.sorted(by: { $0.path < $1.path }) where directory.hasDirectoryPath {
            guard (try? self.validateManagedHome(directory)) != nil,
                  knownPaths.insert(directory.standardizedFileURL.path).inserted else { continue }
            accounts.append(self.account(id: directory.lastPathComponent, homeURL: directory, source: .saved)
                ?? CodexAccount(id: directory.lastPathComponent, email: "", homePath: directory.path, source: .saved))
        }
        return accounts
    }

    public func authData(for account: CodexAccount) throws -> Data {
        let url = URL(fileURLWithPath: account.homePath).appendingPathComponent("auth.json")
        guard self.fileManager.fileExists(atPath: url.path) else { throw CodexUsageError.authFileMissing }
        return try Data(contentsOf: url)
    }

    public func isCurrentAccount(_ account: CodexAccount) -> Bool {
        if account.source == .system { return true }
        let current = Self.credentials(at: self.systemHomeURL)
        if let credentials = try? self.credentials(for: account), credentials.isAPIKey, current?.isAPIKey == true {
            return credentials.accessToken == current?.accessToken
        }
        return Self.sameIdentity(account.identity, current?.identity)
    }

    public func synchronizeSystemCredentials() throws {
        let systemURL = self.systemHomeURL.appendingPathComponent("auth.json")
        guard let systemData = try? Data(contentsOf: systemURL),
              let systemCredentials = try? Self.parseCredentials(data: systemData) else { return }
        let matches = self.managedAccounts().filter { Self.sameIdentity($0.identity, systemCredentials.identity) }
        var newestData = systemData
        var newestCredentials = systemCredentials
        for saved in matches {
            guard let data = try? self.authData(for: saved),
                  let credentials = try? Self.parseCredentials(data: data) else { continue }
            let isNewer: Bool
            if let candidate = credentials.refreshedAt, let current = newestCredentials.refreshedAt {
                isNewer = candidate > current
            } else if let candidate = credentials.expiresAt, let current = newestCredentials.expiresAt {
                isNewer = candidate > current
            } else {
                isNewer = false
            }
            if isNewer {
                newestData = data
                newestCredentials = credentials
            }
        }
        guard (try? Data(contentsOf: systemURL)) == systemData else { throw CodexUsageError.credentialsChanged }
        if newestData != systemData { try self.writePrivate(newestData, to: systemURL) }
        for saved in matches where (try? self.authData(for: saved)) != newestData {
            try self.writePrivate(newestData, to: URL(fileURLWithPath: saved.homePath).appendingPathComponent("auth.json"))
        }
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
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: homeURL.path)
        return homeURL
    }

    public func createTemporaryHome() throws -> URL {
        let homeURL = self.applicationSupportURL.appendingPathComponent("staging")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        return homeURL
    }

    public func discardTemporaryHome(_ homeURL: URL) {
        let parent = self.applicationSupportURL.appendingPathComponent("staging").standardizedFileURL
        guard homeURL.standardizedFileURL.deletingLastPathComponent() == parent else { return }
        try? self.fileManager.removeItem(at: homeURL)
    }

    public func stageCredentials(_ data: Data, at homeURL: URL) throws {
        let parent = self.applicationSupportURL.appendingPathComponent("staging").standardizedFileURL
        guard homeURL.standardizedFileURL.deletingLastPathComponent() == parent else {
            throw CodexUsageError.accountStorage("无效的临时账号目录")
        }
        try self.writePrivate(data, to: homeURL.appendingPathComponent("auth.json"))
    }

    @discardableResult
    public func registerManagedAccount(at homeURL: URL) throws -> CodexAccount {
        try self.validateManagedHome(homeURL)
        let data = try Data(contentsOf: homeURL.appendingPathComponent("auth.json"))
        let credentials = try Self.parseCredentials(data: data)
        let alreadyRegistered = self.loadSavedAccounts().contains { $0.homePath == homeURL.standardizedFileURL.path }
        let existing = alreadyRegistered ? nil : self.managedAccounts().first {
            $0.homePath != homeURL.standardizedFileURL.path && Self.sameIdentity($0.identity, credentials.identity)
        }
        let destination = existing.map { URL(fileURLWithPath: $0.homePath, isDirectory: true) } ?? homeURL
        let id = existing?.id ?? homeURL.lastPathComponent
        try self.writePrivate(data, to: destination.appendingPathComponent("auth.json"))
        let account = CodexAccount(
            id: id,
            email: credentials.email ?? id,
            accountID: credentials.accountID,
            homePath: destination.standardizedFileURL.path,
            source: .saved, userID: credentials.userID)
        var saved = self.loadSavedAccounts().filter { $0.id != id && $0.homePath != account.homePath }
        saved.append(SavedAccount(
            id: account.id,
            homePath: account.homePath,
            email: account.email,
            accountID: account.accountID, userID: account.userID))
        try self.saveSavedAccounts(saved)
        if destination.standardizedFileURL != homeURL.standardizedFileURL {
            try self.removeManagedAccountFiles(at: homeURL)
        }
        for duplicate in self.managedAccounts() where Self.sameIdentity(duplicate.identity, credentials.identity) {
            if (try? self.authData(for: duplicate)) != data {
                try self.writePrivate(data, to: URL(fileURLWithPath: duplicate.homePath).appendingPathComponent("auth.json"))
            }
        }
        if Self.sameIdentity(credentials.identity, Self.credentials(at: self.systemHomeURL)?.identity) {
            try self.writePrivate(data, to: self.systemHomeURL.appendingPathComponent("auth.json"))
            try self.synchronizeSystemCredentials()
            return self.account(id: "system", homeURL: self.systemHomeURL, source: .system) ?? account
        }
        return self.loadAccounts().first(where: { Self.sameIdentity($0.identity, account.identity) }) ?? account
    }

    @discardableResult
    public func importLogin(at homeURL: URL) throws -> CodexAccount {
        let data = try Data(contentsOf: homeURL.appendingPathComponent("auth.json"))
        let credentials = try Self.parseCredentials(data: data)
        guard !credentials.isAPIKey else { throw CodexUsageError.unsupportedAuth }
        let managedHome = try self.createManagedHome()
        do {
            try self.writePrivate(data, to: managedHome.appendingPathComponent("auth.json"))
            return try self.registerManagedAccount(at: managedHome)
        } catch {
            self.removeManagedHome(managedHome)
            throw error
        }
    }

    @discardableResult
    public func replaceCredentials(
        for account: CodexAccount, with data: Data, expectedData: Data?) throws -> CodexAccount
    {
        let credentials = try Self.parseCredentials(data: data)
        guard !credentials.isAPIKey else { throw CodexUsageError.unsupportedAuth }
        guard Self.sameIdentity(account.identity, credentials.identity) else {
            throw CodexUsageError.identityMismatch
        }
        guard (try? self.authData(for: account)) == expectedData else {
            throw CodexUsageError.credentialsChanged
        }
        if account.source == .saved {
            try self.validateManagedHome(URL(fileURLWithPath: account.homePath, isDirectory: true))
            guard self.managedAccounts().contains(where: { $0.id == account.id && $0.homePath == account.homePath }) else {
                throw CodexUsageError.credentialsChanged
            }
        }
        let systemData = try? Data(contentsOf: self.systemHomeURL.appendingPathComponent("auth.json"))
        if self.isCurrentAccount(account), systemData != expectedData {
            throw CodexUsageError.credentialsChanged
        }
        try self.writePrivate(data, to: URL(fileURLWithPath: account.homePath).appendingPathComponent("auth.json"))
        if account.source == .saved {
            return try self.registerManagedAccount(at: URL(fileURLWithPath: account.homePath, isDirectory: true))
        }
        try self.synchronizeSystemCredentials()
        return self.account(id: "system", homeURL: self.systemHomeURL, source: .system) ?? account
    }

    /// Makes the selected profile the account used by the regular Codex CLI.
    /// The current auth file is first copied into an app-owned profile so switching back is possible.
    public func activate(_ account: CodexAccount) throws {
        guard account.source == .saved else { return }
        try self.synchronizeSystemCredentials()
        try self.validateManagedHome(URL(fileURLWithPath: account.homePath, isDirectory: true))
        let targetURL = URL(fileURLWithPath: account.homePath, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        let targetData: Data
        do {
            targetData = try Data(contentsOf: targetURL)
            let credentials = try Self.parseCredentials(data: targetData)
            if !credentials.isAPIKey, !Self.sameIdentity(account.identity, credentials.identity) {
                throw CodexUsageError.credentialsChanged
            }
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.accountSwitch("目标账号的 auth.json 无法读取")
        }

        let systemURL = self.systemHomeURL.appendingPathComponent("auth.json", isDirectory: false)
        let currentData = try? Data(contentsOf: systemURL)
        if let currentData, currentData != targetData {
            guard (try? Self.parseCredentials(data: currentData)) != nil else {
                throw CodexUsageError.accountSwitch("当前账号备份失败")
            }
            let backupURL = try self.createManagedHome()
            do {
                try self.writePrivate(currentData, to: backupURL.appendingPathComponent("auth.json"))
                _ = try self.registerManagedAccount(at: backupURL)
            } catch {
                self.removeManagedHome(backupURL)
                throw CodexUsageError.accountSwitch("当前账号备份失败")
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
        try? self.removeManagedAccountFiles(at: homeURL)
    }

    public func removeAccount(_ account: CodexAccount) throws {
        guard !self.isCurrentAccount(account) else { throw CodexUsageError.currentAccountRemoval }
        try self.validateManagedHome(URL(fileURLWithPath: account.homePath, isDirectory: true))
        let matches = self.managedAccounts().filter {
            $0.id == account.id || Self.sameIdentity($0.identity, account.identity)
        }
        guard !matches.isEmpty else { throw CodexUsageError.credentialsChanged }
        if let actual = matches.first(where: { $0.id == account.id }), account.identity != nil,
           !Self.sameIdentity(account.identity, actual.identity)
        {
            throw CodexUsageError.credentialsChanged
        }
        for match in matches {
            try self.validateManagedHome(URL(fileURLWithPath: match.homePath, isDirectory: true))
            guard !self.isCurrentAccount(match) else { throw CodexUsageError.currentAccountRemoval }
        }
        let saved = self.loadSavedAccounts()
        let removedPaths = Set(matches.map(\.homePath))
        try self.saveSavedAccounts(saved.filter { !removedPaths.contains($0.homePath) })
        do {
            for match in matches where self.fileManager.fileExists(atPath: match.homePath) {
                try self.fileManager.removeItem(at: URL(fileURLWithPath: match.homePath, isDirectory: true))
            }
        } catch {
            try self.saveSavedAccounts(saved)
            throw error
        }
    }

    private func removeManagedAccountFiles(at homeURL: URL) throws {
        try self.validateManagedHome(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
        let path = homeURL.standardizedFileURL.path
        let saved = self.loadSavedAccounts().filter { $0.homePath != path }
        try self.saveSavedAccounts(saved)
    }

    private func validateManagedHome(_ homeURL: URL) throws {
        let parent = self.savedHomesURL.standardizedFileURL.resolvingSymlinksInPath()
        guard homeURL.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == parent,
              homeURL.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == parent else {
            throw CodexUsageError.accountStorage("目录不属于此应用的已保存账号")
        }
    }

    public static func parseCredentials(data: Data) throws -> CodexCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidAuth
        }

        if let apiKey = Self.nonEmptyString(json["OPENAI_API_KEY"]) {
            return CodexCredentials(accessToken: apiKey, accountID: nil, email: nil, isAPIKey: true)
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

        let userID = Self.nonEmptyString(authClaims?["chatgpt_user_id"])
            ?? Self.nonEmptyString(claims?["sub"])
        let expiry = (Self.jwtClaims(accessToken)?["exp"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let refreshedAt = Self.nonEmptyString(json["last_refresh"]).flatMap { value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        return CodexCredentials(accessToken: accessToken, accountID: accountID, email: email,
                                userID: userID, expiresAt: expiry, refreshedAt: refreshedAt)
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
            source: source, userID: credentials.userID)
    }

    private static func credentials(at homeURL: URL) -> CodexCredentials? {
        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        return try? Self.parseCredentials(data: Data(contentsOf: authURL))
    }

    private static func sameIdentity(_ lhs: CodexIdentity?, _ rhs: CodexIdentity?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.matches(rhs)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try self.fileManager.setAttributes(
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
