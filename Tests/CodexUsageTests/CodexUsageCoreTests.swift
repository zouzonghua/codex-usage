import Foundation
import Testing
@testable import CodexUsageCore

struct CodexUsageCoreTests {
    @Test func parsesOAuthCredentialsAndAccountClaims() throws {
        let payload = #"{"email":"dev@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"acct_123"}}"#
        let token = "header.\(Self.base64URL(payload)).signature"
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "access", "id_token": token],
        ])

        let credentials = try CodexAccountStore.parseCredentials(data: data)

        #expect(credentials.accessToken == "access")
        #expect(credentials.accountID == "acct_123")
        #expect(credentials.email == "dev@example.com")
    }

    @Test func parsesUsageResetCreditAndSubscriptionPayloads() throws {
        let usageData = Data(#"""
        {
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {"used_percent": 25, "reset_at": 2000000000},
                "secondary_window": {"used_percent": "40", "reset_at": "2000600000"}
            },
            "credits": {"balance": "12.5"}
        }
        """#.utf8)
        let resetData = Data(#"""
        {
            "available_count": 2,
            "credits": [
                {"status":"available","expires_at":"2099-01-01T00:00:00Z"},
                {"status":"redeemed","expires_at":"2020-01-01T00:00:00Z"},
                {"status":"available"}
            ]
        }
        """#.utf8)
        let subscriptionData = Data(#"{"plan_type":"pro","active_until":"2099-01-01T00:00:00Z","will_renew":true}"#.utf8)

        let response = try CodexUsageClient.decodeUsageResponse(data: usageData)
        let reset = try CodexUsageClient.decodeResetCredits(data: resetData)
        let subscription = try CodexUsageClient.decodeSubscription(data: subscriptionData)

        #expect(response.planType == "pro")
        #expect(response.rateLimit?.primaryWindow?.usedPercent?.value == 25)
        #expect(response.rateLimit?.secondaryWindow?.usedPercent?.value == 40)
        #expect(response.credits?.balance?.value == 12.5)
        #expect(reset.availableCount == 2)
        #expect(reset.nextExpiry != nil)
        #expect(subscription.activeUntil?.value == Date(timeIntervalSince1970: 4070908800))
    }

    @Test func resolvesCodexBaseURLFromConfig() {
        let url = CodexUsageClient.resolveBaseURL(homePath: "/path/that/does/not/exist")
        #expect(url.absoluteString == "https://chatgpt.com/backend-api")
        #expect(
            CodexUsageClient.chatGPTBaseURL(in: "chatgpt_base_url = 'https://example.com/api'")
                == "https://example.com/api")
    }

    @Test func comparesReleaseVersions() {
        #expect(CodexUpdateChecker.Version("v0.2.0")! > CodexUpdateChecker.Version("0.1.0")!)
        #expect(CodexUpdateChecker.Version("v0.1.0-beta.9")! < CodexUpdateChecker.Version("0.1.0")!)
    }

    @Test func switchingAccountPreservesThePreviousSystemAccount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageTests-\(UUID().uuidString)", isDirectory: true)
        let systemHome = root.appendingPathComponent("system", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: systemHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.authData(email: "first@example.com", accountID: "acct_first")
            .write(to: systemHome.appendingPathComponent("auth.json"))
        let store = CodexAccountStore(
            applicationSupportURL: supportURL,
            environment: ["CODEX_HOME": systemHome.path])
        let targetHome = try store.createManagedHome()
        try Self.authData(email: "second@example.com", accountID: "acct_second")
            .write(to: targetHome.appendingPathComponent("auth.json"))
        let target = try store.registerManagedAccount(at: targetHome)

        try store.activate(target)
        let activeAfterFirstSwitch = try #require(store.loadAccounts().first(where: { $0.source == .system }))
        #expect(try store.credentials(for: activeAfterFirstSwitch).email == "second@example.com")
        #expect(store.loadAccounts().contains { $0.email == "first@example.com" && $0.source == .saved })

        let first = try #require(store.loadAccounts().first { $0.email == "first@example.com" })
        try store.activate(first)
        let activeAfterSecondSwitch = try #require(store.loadAccounts().first(where: { $0.source == .system }))
        #expect(try store.credentials(for: activeAfterSecondSwitch).email == "first@example.com")
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func authData(email: String, accountID: String) throws -> Data {
        let payload = "{\"email\":\"\(email)\","
            + "\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"\(accountID)\"}}"
        let token = "header.\(Self.base64URL(payload)).signature"
        return try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "token-\(accountID)", "id_token": token],
        ])
    }
}
