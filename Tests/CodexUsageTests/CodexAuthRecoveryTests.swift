import Foundation
import Testing
@testable import CodexUsageCore

@MainActor
struct CodexAuthRecoveryTests {
    @Test func renewalIsSharedAndPreservesOtherAccounts() async throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.addAccount("first", expired: true)
        let second = try fixture.addAccount("second")
        let secondData = try fixture.store.authData(for: second)
        let gate = RenewalGate()
        var renewals = 0
        let coordinator = CodexAuthCoordinator(store: fixture.store, now: { AuthFixture.now }) { home in
            renewals += 1
            await gate.pause()
            try AuthFixture.data("first", token: "renewed").write(to: home.appendingPathComponent("auth.json"))
        }
        let initial = Task { try await coordinator.validCredentials(for: first, forceRefresh: true) }
        await gate.waitUntilStarted()
        let joined = Task { try await coordinator.validCredentials(for: first, forceRefresh: true) }
        await Task.yield()
        gate.release()

        let initialResult = try await initial.value
        let joinedResult = try await joined.value

        #expect(initialResult == joinedResult)
        #expect(renewals == 1)
        #expect(try fixture.store.credentials(for: first) == initialResult)
        #expect(try fixture.store.authData(for: second) == secondData)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.systemHomeURL.appendingPathComponent("auth.json").path))
        #expect(try fixture.temporaryHomes().isEmpty)
    }

    @Test(arguments: ["retry", "unauthorized", "forbidden", "offline"])
    func retriesOnlyUnauthorizedOnce(mode: String) async throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first")
        var renewals = 0
        let coordinator = CodexAuthCoordinator(store: fixture.store, now: { AuthFixture.now }) { home in
            renewals += 1
            try AuthFixture.data("first", token: "renewed").write(to: home.appendingPathComponent("auth.json"))
        }
        let host = "\(mode)-\(UUID().uuidString.lowercased()).invalid"
        defer { RecoveryURLProtocol.requests.remove(host) }
        let client = Self.client(host: host)
        if mode == "retry" {
            let (usage, credentials) = try await coordinator.fetchUsage(for: account, client: client)
            #expect(usage.planType == "pro")
            #expect(credentials.accessToken.hasPrefix("renewed."))
        } else {
            do {
                _ = try await coordinator.fetchUsage(for: account, client: client)
                Issue.record("Expected the simulated failure")
            } catch let error as CodexUsageError {
                if mode == "unauthorized" { #expect(error == .unauthorized) }
                if mode == "forbidden" { #expect(error == .forbidden) }
                if mode == "offline" {
                    guard case .network = error else { Issue.record("Network failure was misclassified"); return }
                }
            }
        }
        let shouldRenew = mode == "retry" || mode == "unauthorized"
        #expect(renewals == (shouldRenew ? 1 : 0))
        let requests = RecoveryURLProtocol.requests.read(host)
        #expect(requests.count == (shouldRenew ? 2 : 1))
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "first" })
        if shouldRenew {
            #expect(requests.last?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer renewed.") == true)
        }
    }

    @Test func anExpiredTokenDoesNotRenewAgainAfter401() async throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first", expired: true)
        var renewals = 0
        let coordinator = CodexAuthCoordinator(store: fixture.store, now: { AuthFixture.now }) { home in
            renewals += 1
            try AuthFixture.data("first", token: "renewed").write(to: home.appendingPathComponent("auth.json"))
        }
        let host = "unauthorized-\(UUID().uuidString).invalid"
        defer { RecoveryURLProtocol.requests.remove(host) }
        await #expect(throws: CodexUsageError.unauthorized) {
            _ = try await coordinator.fetchUsage(for: account, client: Self.client(host: host))
        }
        #expect(renewals == 1)
        #expect(RecoveryURLProtocol.requests.read(host).count == 1)
    }

    @Test func failedRenewalPreservesCredentials() async throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first", expired: true)
        let original = try fixture.store.authData(for: account)
        let coordinator = CodexAuthCoordinator(store: fixture.store, now: { AuthFixture.now }) { _ in
            throw CodexUsageError.authenticationUnavailable
        }
        await #expect(throws: CodexUsageError.authenticationUnavailable) {
            _ = try await coordinator.validCredentials(for: account)
        }
        #expect(try fixture.store.authData(for: account) == original)
        #expect(try fixture.temporaryHomes().isEmpty)
    }

    @Test(arguments: [false, true])
    func externalLoginDuringRenewalIsNeverOverwritten(switchIdentity: Bool) async throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let saved = try fixture.addAccount("first", expired: true)
        try fixture.store.activate(saved)
        let system = try #require(fixture.store.loadAccounts().first { $0.source == .system })
        let external = try AuthFixture.data(switchIdentity ? "second" : "first", token: "external")
        let coordinator = CodexAuthCoordinator(store: fixture.store, now: { AuthFixture.now }) { home in
            try external.write(to: fixture.store.systemHomeURL.appendingPathComponent("auth.json"))
            try AuthFixture.data("first", token: "renewed").write(to: home.appendingPathComponent("auth.json"))
        }
        if switchIdentity {
            await #expect(throws: CodexUsageError.credentialsChanged) {
                _ = try await coordinator.validCredentials(for: system)
            }
        } else {
            let credentials = try await coordinator.validCredentials(for: system)
            #expect(credentials.accessToken.hasPrefix("external."))
        }
        #expect(try fixture.store.authData(for: system) == external)
    }

    @Test func cancellingRenewalBeforeDeletionCannotRecreateTheAccount() async throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first", expired: true)
        let gate = RenewalGate()
        let coordinator = CodexAuthCoordinator(store: fixture.store, now: { AuthFixture.now }) { home in
            await gate.pause()
            try AuthFixture.data("first", token: "renewed").write(to: home.appendingPathComponent("auth.json"))
        }
        let request = Task { try await coordinator.validCredentials(for: account) }
        await gate.waitUntilStarted()
        let cancellation = Task { await coordinator.cancel(for: account) }
        await Task.yield()
        gate.release()
        await cancellation.value
        _ = try? await request.value
        try fixture.store.removeAccount(account)
        #expect(fixture.store.loadAccounts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: account.homePath))
        #expect(try fixture.temporaryHomes().isEmpty)
    }

    @Test func deletionChecksLiveSystemIdentityAndSurvivesRestart() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.addAccount("first")
        let second = try fixture.addAccount("second")
        try fixture.store.activate(first)
        #expect(throws: CodexUsageError.currentAccountRemoval) { try fixture.store.removeAccount(first) }
        try fixture.store.activate(second)
        try fixture.store.removeAccount(first)
        let restarted = CodexAccountStore(
            applicationSupportURL: fixture.store.applicationSupportURL,
            environment: ["CODEX_HOME": fixture.store.systemHomeURL.path])
        #expect(!restarted.loadAccounts().contains { $0.accountID == "first" })
        #expect(restarted.loadAccounts().contains { $0.accountID == "second" })
    }

    @Test func damagedCredentialsRemainDeletable() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first")
        try Data("broken".utf8).write(to: URL(fileURLWithPath: account.homePath).appendingPathComponent("auth.json"))
        let damaged = try #require(fixture.store.loadAccounts().first { $0.id == account.id })
        #expect(damaged.email == account.email)
        try fixture.store.removeAccount(damaged)
        #expect(fixture.store.loadAccounts().isEmpty)
    }

    @Test func failedIndexWriteDoesNotDeleteCredentials() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first")
        let index = fixture.store.applicationSupportURL.appendingPathComponent("accounts.json")
        let savedIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try fixture.store.removeAccount(account) }
        #expect(FileManager.default.fileExists(atPath: account.homePath))
        try FileManager.default.removeItem(at: index)
        try savedIndex.write(to: index)
        try fixture.store.removeAccount(account)
        #expect(fixture.store.loadAccounts().isEmpty)
    }

    @Test func managedHomeCannotEscapeThroughASymlink() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let home = try fixture.store.createManagedHome()
        try FileManager.default.removeItem(at: home)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: fixture.store.systemHomeURL)
        let account = CodexAccount(id: home.lastPathComponent, email: "", homePath: home.path, source: .saved)
        #expect(throws: (any Error).self) { try fixture.store.removeAccount(account) }
        #expect(FileManager.default.fileExists(atPath: fixture.store.systemHomeURL.path))
    }

    @Test func targetedLoginRetainsIDAndRejectsAnotherUserInTheSameWorkspace() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("workspace", user: "first")
        let original = try fixture.store.authData(for: account)
        let wrongUser = try AuthFixture.data("workspace", user: "second", token: "wrong")
        #expect(throws: CodexUsageError.identityMismatch) {
            try fixture.store.replaceCredentials(for: account, with: wrongUser, expectedData: original)
        }
        #expect(try fixture.store.authData(for: account) == original)
        let renewed = try AuthFixture.data("workspace", user: "first", token: "renewed")
        let result = try fixture.store.replaceCredentials(for: account, with: renewed, expectedData: original)
        #expect(result.id == account.id)
        #expect(fixture.store.loadAccounts().count == 1)
        #expect(throws: CodexUsageError.credentialsChanged) {
            try fixture.store.replaceCredentials(for: account, with: original, expectedData: original)
        }
    }

    @Test func duplicateLoginUpdatesTheExistingProfile() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first")
        let duplicate = try fixture.addAccount("first", token: "renewed")
        #expect(duplicate.id == account.id)
        #expect(fixture.store.managedAccounts().count == 1)
        #expect(try fixture.store.credentials(for: account).accessToken.hasPrefix("renewed."))
    }

    @Test func synchronizationKeepsTheNewerManagedLogin() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first")
        let original = try fixture.store.authData(for: account)
        try original.write(to: fixture.store.systemHomeURL.appendingPathComponent("auth.json"))
        var renewed = try #require(JSONSerialization.jsonObject(with: AuthFixture.data("first", token: "external")) as? [String: Any])
        renewed["last_refresh"] = ISO8601DateFormatter().string(from: AuthFixture.now.addingTimeInterval(60))
        let newerData = try JSONSerialization.data(withJSONObject: renewed)
        try newerData.write(to: URL(fileURLWithPath: account.homePath).appendingPathComponent("auth.json"))

        try fixture.store.synchronizeSystemCredentials()

        #expect(try fixture.store.authData(for: account) == newerData)
        #expect(try Data(contentsOf: fixture.store.systemHomeURL.appendingPathComponent("auth.json")) == newerData)
    }

    @Test func switchingPreservesAnExistingAPIKeyLogin() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let account = try fixture.addAccount("first")
        let apiKey = Data(#"{"OPENAI_API_KEY":"fixture-key"}"#.utf8)
        try apiKey.write(to: fixture.store.systemHomeURL.appendingPathComponent("auth.json"))
        try fixture.store.activate(account)
        let backup = try #require(fixture.store.managedAccounts().first {
            (try? fixture.store.credentials(for: $0).isAPIKey) == true
        })
        #expect(try fixture.store.authData(for: backup) == apiKey)
        try fixture.store.activate(backup)
        #expect(try Data(contentsOf: fixture.store.systemHomeURL.appendingPathComponent("auth.json")) == apiKey)
        #expect(throws: CodexUsageError.currentAccountRemoval) { try fixture.store.removeAccount(backup) }
    }

    @Test func sameWorkspaceDifferentUsersRemainSeparate() throws {
        let fixture = try AuthFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.addAccount("workspace", user: "first")
        let second = try fixture.addAccount("workspace", user: "second")
        #expect(first.cacheKey != second.cacheKey)
        #expect(fixture.store.loadAccounts().count == 2)
    }

    @Test func apiKeysAreNotSentToTheUsageEndpoint() async throws {
        let credentials = try CodexAccountStore.parseCredentials(data: Data(#"{"OPENAI_API_KEY":"fake-key"}"#.utf8))
        let host = "retry-\(UUID().uuidString).invalid"
        defer { RecoveryURLProtocol.requests.remove(host) }
        await #expect(throws: CodexUsageError.unsupportedAuth) {
            _ = try await Self.client(host: host).fetchUsage(credentials: credentials, homePath: "/unused")
        }
        #expect(RecoveryURLProtocol.requests.read(host).isEmpty)
    }

    private static func client(host: String) -> CodexUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        return CodexUsageClient(session: URLSession(configuration: configuration), baseURL: URL(string: "https://\(host)/backend-api")!)
    }
}

@MainActor
private final class AuthFixture {
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    let root: URL
    let store: CodexAccountStore

    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexAuthTests-\(UUID().uuidString)")
        self.store = CodexAccountStore(applicationSupportURL: self.root.appendingPathComponent("support"),
                                      environment: ["CODEX_HOME": self.root.appendingPathComponent("system").path])
        try FileManager.default.createDirectory(at: self.store.systemHomeURL, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: self.root) }

    func addAccount(_ accountID: String, user: String = "person", token: String = "original", expired: Bool = false) throws -> CodexAccount {
        let home = try self.store.createManagedHome()
        try Self.data(accountID, user: user, token: token, expired: expired).write(to: home.appendingPathComponent("auth.json"))
        return try self.store.registerManagedAccount(at: home)
    }

    func temporaryHomes() throws -> [URL] {
        let staging = self.store.applicationSupportURL.appendingPathComponent("staging")
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
    }

    static func data(_ accountID: String, user: String = "person", token: String = "original", expired: Bool = false) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": "\(user)@example.com", "sub": user,
            "exp": self.now.timeIntervalSince1970 + (expired ? -60 : 3600),
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
        ])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let jwt = "\(token).\(encoded).signature"
        return try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt", "last_refresh": ISO8601DateFormatter().string(from: self.now.addingTimeInterval(expired ? -3600 : 0)),
            "tokens": ["access_token": jwt, "id_token": jwt,
                                                "account_id": accountID, "refresh_token": "refresh-\(token)"],
        ])
    }
}

@MainActor
private final class RenewalGate {
    private var started = false
    private var waitingForStart: CheckedContinuation<Void, Never>?
    private var waitingForRelease: CheckedContinuation<Void, Never>?

    func pause() async {
        self.started = true
        self.waitingForStart?.resume()
        self.waitingForStart = nil
        await withCheckedContinuation { self.waitingForRelease = $0 }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { self.waitingForStart = $0 }
    }

    func release() {
        self.waitingForRelease?.resume()
        self.waitingForRelease = nil
    }
}

private final class RecoveryRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [URLRequest]] = [:]

    func append(_ request: URLRequest, host: String) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.values[host, default: []].append(request)
        return self.values[host, default: []].count
    }

    func read(_ host: String) -> [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values[host, default: []]
    }

    func remove(_ host: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.values[host] = nil
    }
}

private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = RecoveryRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = self.request.url!.host!
        let attempt = Self.requests.append(self.request, host: host)
        if host.hasPrefix("offline-") {
            self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = host.hasPrefix("forbidden-") ? 403
            : (host.hasPrefix("unauthorized-") || attempt == 1 ? 401 : 200)
        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(#"{"plan_type":"pro"}"#.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
