import Foundation

@MainActor
public final class CodexAuthCoordinator {
    private struct Refresh {
        let id: UUID
        let task: Task<CodexCredentials, Error>
    }

    private let store: CodexAccountStore
    private let renew: @MainActor (URL) async throws -> Void
    private let now: () -> Date
    private var refreshes: [String: Refresh] = [:]

    public init(
        store: CodexAccountStore,
        now: @escaping () -> Date = Date.init,
        renew: @escaping @MainActor (URL) async throws -> Void = { try await CodexCLI().refreshCredentials(at: $0) })
    {
        self.store = store
        self.now = now
        self.renew = renew
    }

    public func validCredentials(for account: CodexAccount, forceRefresh: Bool = false) async throws -> CodexCredentials {
        try Task.checkCancellation()
        let key = account.cacheKey
        if let pending = self.refreshes[key] {
            let result = try await pending.task.value
            try Task.checkCancellation()
            return result
        }
        try self.store.synchronizeSystemCredentials()
        let original = try self.store.authData(for: account)
        let credentials = try CodexAccountStore.parseCredentials(data: original)
        guard !credentials.isAPIKey else { throw CodexUsageError.unsupportedAuth }
        guard let identity = account.identity, let actualIdentity = credentials.identity,
              identity.matches(actualIdentity) else { throw CodexUsageError.credentialsChanged }
        if !forceRefresh, credentials.expiresAt.map({ $0 > self.now().addingTimeInterval(60) }) ?? true {
            return credentials
        }
        let id = UUID()
        let task = Task { @MainActor in
            let temporaryHome = try self.store.createTemporaryHome()
            defer { self.store.discardTemporaryHome(temporaryHome) }
            try self.store.stageCredentials(original, at: temporaryHome)
            do {
                try await self.renew(temporaryHome)
                try Task.checkCancellation()
                let data = try Data(contentsOf: temporaryHome.appendingPathComponent("auth.json"))
                let renewed = try CodexAccountStore.parseCredentials(data: data)
                guard renewed.expiresAt.map({ $0 > self.now() }) ?? (renewed.accessToken != credentials.accessToken) else {
                    throw CodexUsageError.unauthorized
                }
                _ = try self.store.replaceCredentials(for: account, with: data, expectedData: original)
                return renewed
            } catch {
                try Task.checkCancellation()
                try self.store.synchronizeSystemCredentials()
                if let latestData = try? self.store.authData(for: account), latestData != original,
                   let latest = try? CodexAccountStore.parseCredentials(data: latestData),
                   let latestIdentity = latest.identity, identity.matches(latestIdentity),
                   latest.expiresAt.map({ $0 > self.now() }) ?? false
                {
                    return latest
                }
                throw error
            }
        }
        self.refreshes[key] = Refresh(id: id, task: task)
        defer {
            if self.refreshes[key]?.id == id { self.refreshes[key] = nil }
        }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    public func fetchUsage(for account: CodexAccount, client: CodexUsageClient) async throws -> (CodexUsage, CodexCredentials) {
        try self.store.synchronizeSystemCredentials()
        let original = try self.store.credentials(for: account)
        let expired = original.expiresAt.map { $0 <= self.now().addingTimeInterval(60) } ?? false
        var credentials = try await self.validCredentials(for: account)
        do {
            return (try await client.fetchUsage(credentials: credentials, homePath: account.homePath), credentials)
        } catch CodexUsageError.unauthorized {
            guard !expired else { throw CodexUsageError.unauthorized }
            try Task.checkCancellation()
            let latest = try self.store.credentials(for: account)
            credentials = try await self.validCredentials(
                for: account, forceRefresh: latest.accessToken == credentials.accessToken)
            return (try await client.fetchUsage(credentials: credentials, homePath: account.homePath), credentials)
        }
    }

    public func cancel(for account: CodexAccount) async {
        guard let refresh = self.refreshes[account.cacheKey] else { return }
        refresh.task.cancel()
        _ = try? await refresh.task.value
        if self.refreshes[account.cacheKey]?.id == refresh.id { self.refreshes[account.cacheKey] = nil }
    }

    public func cancelAll() {
        for refresh in self.refreshes.values { refresh.task.cancel() }
    }
}
