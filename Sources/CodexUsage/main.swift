import AppKit
import CodexUsageCore

private struct CachedResetCredits: Codable, Sendable {
    let availableCount: Int
    let nextExpiry: Date?

    init(_ summary: CodexResetCreditSummary) {
        self.availableCount = summary.availableCount
        self.nextExpiry = summary.nextExpiry
    }

    var summary: CodexResetCreditSummary {
        CodexResetCreditSummary(availableCount: self.availableCount, nextExpiry: self.nextExpiry)
    }
}

private struct DailyUsageCache: Codable, Sendable {
    var resetCredits: CachedResetCredits?
    var subscriptionExpiresAt: Date?
    var lastResetCreditsAttemptAt: Date?
    var lastSubscriptionAttemptAt: Date?
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
    private static var appReleaseVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CodexUsageReleaseTag") as? String ?? Self.appVersion
    }
    private static let automaticRefreshInterval: TimeInterval = 300
    private static let menuRefreshInterval: TimeInterval = 300
    private static let resetCreditsRefreshInterval: TimeInterval = 10 * 60
    private static let subscriptionRefreshInterval: TimeInterval = 24 * 60 * 60
    private static let dailyDataCacheKey = "dailyUsageCacheV2"
    private let accountStore = CodexAccountStore()
    private lazy var authCoordinator = CodexAuthCoordinator(store: self.accountStore)
    private let usageClient = CodexUsageClient()
    private let updateChecker = CodexUpdateChecker()
    private var statusItem: NSStatusItem!
    private var language = CodexLanguage.load()
    private var accounts: [CodexAccount] = []
    private var selectedAccountID: String?
    private var usageByAccount: [String: CodexUsage] = [:]
    private var dailyUsageCacheByAccount: [String: DailyUsageCache] = [:]
    private var errorByAccount: [String: CodexUsageError] = [:]
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var refreshRequestID: UUID?
    private var refreshingAccountID: String?
    private var accountOperationTask: Task<Void, Never>?
    private var loginInProgress = false
    private var observedCredentials: [String: CodexCredentials] = [:]
    private var needsRefresh: Set<String> = []
    private var accountStoreError: CodexUsageError?
    private var isTerminating = false
    private var text: AppText {
        AppText(language: self.language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)

        // macOS 15 can drop a status item created during didFinishLaunching.
        // Create it on the next main-run-loop turn instead.
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    private func start() {
        guard self.statusItem == nil else { return }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem.button?.image = CodexStatusIcon.image(primaryRemaining: nil, weeklyRemaining: nil)
        self.statusItem.button?.imagePosition = .imageOnly
        self.statusItem.button?.setAccessibilityTitle(self.text.statusAccessibilityTitle)

        _ = self.reloadAccounts()
        self.dailyUsageCacheByAccount = Self.loadDailyUsageCache()
        let savedSelection = UserDefaults.standard.string(forKey: "selectedAccountID")
        self.selectedAccountID = self.accounts.contains { $0.id == savedSelection }
            ? savedSelection
            : self.accounts.first?.id
        self.rebuildMenu()
        self.refreshSelectedAccount()

        self.refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.automaticRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSelectedAccount(ifOlderThan: Self.automaticRefreshInterval)
            }
        }
        self.clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusIcon()
                self?.rebuildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        self.isTerminating = true
        self.refreshTimer?.invalidate()
        self.clockTimer?.invalidate()
        self.refreshTask?.cancel()
        self.updateCheckTask?.cancel()
        self.accountOperationTask?.cancel()
        self.authCoordinator.cancelAll()
    }

    func menuWillOpen(_ menu: NSMenu) {
        _ = menu
        self.rebuildMenu()
        self.refreshSelectedAccount(ifOlderThan: Self.menuRefreshInterval)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        if let account = self.selectedAccount {
            if !account.email.isEmpty {
                menu.addItem(self.infoItem(title: account.email))
                menu.addItem(.separator())
            }
            if let usage = self.usageByAccount[account.cacheKey] {
                menu.addItem(self.infoItem(title: self.text.fiveHourQuota(usage.primary)))
                menu.addItem(self.infoItem(title: self.text.weeklyQuota(usage.secondary)))
                if let credits = usage.credits {
                    menu.addItem(self.infoItem(title: self.text.credits(credits)))
                }
                if let resetCredits = usage.resetCredits {
                    menu.addItem(self.infoItem(title: self.text.resetCredits(resetCredits)))
                } else {
                    menu.addItem(self.infoItem(title: self.text.resetCreditsUnavailable))
                }
                if let planType = usage.planType, !planType.isEmpty {
                    menu.addItem(self.infoItem(title: "\(self.text.plan)：\(planType)"))
                }
                menu.addItem(self.infoItem(title: self.text.subscriptionExpiry(usage.subscriptionExpiresAt)))
                menu.addItem(.separator())
                menu.addItem(self.infoItem(title: self.text.updated(usage.fetchedAt)))
            } else if self.refreshingAccountID == account.id {
                menu.addItem(self.infoItem(title: self.text.refreshing))
            } else {
                menu.addItem(self.infoItem(title: self.text.noUsage))
            }
            if let error = self.errorByAccount[account.cacheKey] {
                menu.addItem(self.infoItem(title: self.text.errorMessage(error)))
                if error == .unauthorized || error == .authFileMissing || error == .invalidAuth {
                    let login = NSMenuItem(title: self.text.relogin, action: #selector(reloginAccount(_:)), keyEquivalent: "")
                    login.target = self
                    login.representedObject = account.id
                    login.isEnabled = self.accountOperationTask == nil
                    menu.addItem(login)
                }
            }
        } else {
            menu.addItem(self.infoItem(title: self.text.noAccount))
            menu.addItem(self.infoItem(title: self.text.loginHint))
            menu.addItem(.separator())
        }

        if let error = self.accountStoreError {
            menu.addItem(self.infoItem(title: self.text.errorMessage(error)))
        }
        if self.loginInProgress {
            menu.addItem(self.infoItem(title: self.text.loginInProgress))
        }

        let refreshItem = NSMenuItem(title: self.text.refresh, action: #selector(refreshMenuAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(self.viewAccountUsageMenuItem())
        menu.addItem(self.switchCodexAccountMenuItem())
        menu.addItem(self.manageAccountsMenuItem())
        menu.addItem(.separator())
        menu.addItem(self.languageMenuItem())
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: self.text.about, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updateItem = NSMenuItem(
            title: self.text.checkForUpdates,
            action: #selector(checkForUpdates),
            keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: self.text.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        self.statusItem.menu = menu
        self.updateStatusIcon()
    }

    private func viewAccountUsageMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: self.text.viewAccountUsage, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: self.text.viewAccountUsage)
        for account in self.accounts {
            let item = NSMenuItem(
                title: self.text.accountName(account),
                action: #selector(selectUsageAccount(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.state = account.id == self.selectedAccountID ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func switchCodexAccountMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: self.text.switchCodexAccount, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: self.text.switchCodexAccount)
        let systemAccountID = self.accounts.first(where: { $0.source == .system })?.id
        for account in self.accounts {
            let item = NSMenuItem(
                title: self.text.accountName(account),
                action: #selector(switchCodexAccount(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.state = account.id == systemAccountID ? .on : .off
            item.isEnabled = self.accountOperationTask == nil
            submenu.addItem(item)
        }
        if !self.accounts.isEmpty {
            submenu.addItem(.separator())
        }
        let addItem = NSMenuItem(title: self.text.addAccount, action: #selector(addAccount), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = self.accountOperationTask == nil
        submenu.addItem(addItem)
        parent.submenu = submenu
        return parent
    }

    private func manageAccountsMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: self.text.manageAccounts, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: self.text.manageAccounts)
        for account in self.accounts {
            let entry = NSMenuItem(title: self.text.accountName(account), action: nil, keyEquivalent: "")
            let actions = NSMenu()
            let login = NSMenuItem(title: self.text.relogin, action: #selector(reloginAccount(_:)), keyEquivalent: "")
            login.target = self
            login.representedObject = account.id
            login.isEnabled = self.accountOperationTask == nil
            actions.addItem(login)
            let current = self.accountStore.isCurrentAccount(account)
            let deletion = NSMenuItem(
                title: current ? self.text.accountInUse : self.text.deleteAccount,
                action: #selector(deleteAccount(_:)), keyEquivalent: "")
            deletion.target = self
            deletion.representedObject = account.id
            deletion.isEnabled = !current && self.accountOperationTask == nil
            actions.addItem(deletion)
            entry.submenu = actions
            submenu.addItem(entry)
        }
        if self.loginInProgress {
            submenu.addItem(.separator())
            let cancel = NSMenuItem(title: self.text.cancelLogin, action: #selector(cancelLogin), keyEquivalent: "")
            cancel.target = self
            submenu.addItem(cancel)
        }
        parent.submenu = submenu
        return parent
    }

    private func languageMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: self.text.languageTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: self.text.languageTitle)
        for language in CodexLanguage.allCases {
            let item = NSMenuItem(title: language == .chinese ? "中文" : "English",
                                  action: #selector(selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == self.language ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func infoItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.labelColor])
        return item
    }

    private var selectedAccount: CodexAccount? {
        self.accounts.first { $0.id == self.selectedAccountID }
    }

    @objc private func selectUsageAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              self.reloadAccounts(), let account = self.accounts.first(where: { $0.id == id })
        else { return }

        self.cancelRefresh()
        self.selectedAccountID = id
        self.errorByAccount[account.cacheKey] = nil
        UserDefaults.standard.set(self.selectedAccountID, forKey: "selectedAccountID")
        self.rebuildMenu()
        self.refreshSelectedAccount()
    }

    @objc private func switchCodexAccount(_ sender: NSMenuItem) {
        guard self.accountOperationTask == nil, self.reloadAccounts(),
              let id = sender.representedObject as? String,
              let account = self.accounts.first(where: { $0.id == id })
        else { return }

        self.cancelRefresh()
        self.accountOperationTask = Task { @MainActor in
            defer { self.finishAccountOperation() }
            do {
                if account.source == .saved {
                    if try !self.accountStore.credentials(for: account).isAPIKey {
                        _ = try await self.authCoordinator.validCredentials(for: account)
                    }
                    try Task.checkCancellation()
                    try self.accountStore.activate(account)
                }
                _ = self.reloadAccounts()
                self.selectedAccountID = self.accounts.first(where: { $0.source == .system })?.id
                self.errorByAccount[account.cacheKey] = nil
                self.needsRefresh.insert(account.cacheKey)
                UserDefaults.standard.set(self.selectedAccountID, forKey: "selectedAccountID")
            } catch is CancellationError {
            } catch {
                self.showAlert(title: self.text.unableToSwitchAccount, message: self.text.errorMessage(error))
            }
        }
        self.rebuildMenu()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = CodexLanguage(rawValue: rawValue)
        else { return }
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: CodexLanguage.defaultsKey)
        self.rebuildMenu()
    }

    @objc private func refreshMenuAction() {
        self.refreshSelectedAccount()
    }

    @discardableResult
    private func reloadAccounts() -> Bool {
        do {
            try self.accountStore.synchronizeSystemCredentials()
            let previous = self.selectedAccount
            self.accounts = self.accountStore.loadAccounts()
            if !self.accounts.contains(where: { $0.id == self.selectedAccountID }) {
                self.selectedAccountID = self.accounts.first(where: { $0.cacheKey == previous?.cacheKey })?.id
                    ?? self.accounts.first?.id
                UserDefaults.standard.set(self.selectedAccountID, forKey: "selectedAccountID")
            }
            var observed: [String: CodexCredentials] = [:]
            for account in self.accounts {
                let credentials = try? self.accountStore.credentials(for: account)
                observed[account.cacheKey] = credentials
                if self.observedCredentials[account.cacheKey] != credentials {
                    self.needsRefresh.insert(account.cacheKey)
                    self.errorByAccount[account.cacheKey] = nil
                    if account.id == self.selectedAccountID { self.cancelRefresh() }
                }
            }
            if previous?.cacheKey != self.selectedAccount?.cacheKey { self.cancelRefresh() }
            self.observedCredentials = observed
            self.accountStoreError = nil
            return true
        } catch {
            self.accountStoreError = .accountStorage(error.localizedDescription)
            return false
        }
    }

    private func refreshSelectedAccount(ifOlderThan minimumAge: TimeInterval? = nil) {
        guard self.accountOperationTask == nil, self.reloadAccounts(), let account = self.selectedAccount else {
            self.rebuildMenu()
            return
        }
        if self.refreshingAccountID == account.id {
            return
        }
        if let minimumAge,
           !self.needsRefresh.contains(account.cacheKey),
           let usage = self.usageByAccount[account.cacheKey],
           Date().timeIntervalSince(usage.fetchedAt) < minimumAge
        {
            return
        }
        self.cancelRefresh()
        let requestID = UUID()
        self.refreshRequestID = requestID
        self.refreshingAccountID = account.id
        self.errorByAccount[account.cacheKey] = nil
        self.rebuildMenu()
        let client = self.usageClient
        let homePath = account.homePath
        let cacheKey = account.cacheKey
        self.refreshTask = Task { @MainActor in
            defer {
                if self.refreshRequestID == requestID {
                    self.refreshingAccountID = nil
                    self.refreshTask = nil
                    self.refreshRequestID = nil
                    self.rebuildMenu()
                }
            }
            do {
                let (usage, credentials) = try await self.authCoordinator.fetchUsage(for: account, client: client)
                try Task.checkCancellation()
                guard self.requestStillMatches(account: account, credentials: credentials) else { return }
                self.observedCredentials[cacheKey] = credentials
                let cachedDailyData = self.dailyUsageCacheByAccount[cacheKey]
                let refreshResetCredits = self.shouldRefreshResetCredits(cachedDailyData)
                let refreshSubscription = self.shouldRefreshSubscription(cachedDailyData)
                let refreshAdditionalData = refreshResetCredits || refreshSubscription
                let dailyData: DailyUsageCache
                if refreshAdditionalData {
                    let attemptData = Self.markRefreshAttempts(
                        cachedDailyData,
                        resetCredits: refreshResetCredits,
                        subscription: refreshSubscription)
                    self.dailyUsageCacheByAccount[cacheKey] = attemptData
                    self.saveDailyUsageCache()
                    dailyData = try await self.refreshAdditionalData(
                        cached: attemptData,
                        refreshResetCredits: refreshResetCredits,
                        refreshSubscription: refreshSubscription,
                        client: client,
                        credentials: credentials,
                        homePath: homePath)
                } else {
                    dailyData = cachedDailyData ?? DailyUsageCache(
                        resetCredits: nil,
                        subscriptionExpiresAt: nil,
                        lastResetCreditsAttemptAt: nil,
                        lastSubscriptionAttemptAt: nil)
                }
                try Task.checkCancellation()
                guard self.requestStillMatches(account: account, credentials: credentials) else { return }
                if refreshAdditionalData {
                    self.dailyUsageCacheByAccount[cacheKey] = dailyData
                    self.saveDailyUsageCache()
                }
                let mergedUsage = Self.merge(usage: usage, dailyData: dailyData)
                guard self.selectedAccount?.cacheKey == cacheKey, self.refreshRequestID == requestID else { return }
                self.usageByAccount[cacheKey] = mergedUsage
                self.errorByAccount[cacheKey] = nil
                self.needsRefresh.remove(cacheKey)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self.selectedAccount?.cacheKey == cacheKey,
                      self.refreshRequestID == requestID else { return }
                self.errorByAccount[cacheKey] = self.codexError(error)
            }
        }
    }

    private func requestStillMatches(account: CodexAccount, credentials: CodexCredentials) -> Bool {
        self.accounts.contains(where: { $0.cacheKey == account.cacheKey })
            && (try? self.accountStore.credentials(for: account)) == credentials
    }

    private func cancelRefresh() {
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.refreshRequestID = nil
        self.refreshingAccountID = nil
    }

    private func shouldRefreshResetCredits(_ cache: DailyUsageCache?) -> Bool {
        guard let lastAttemptAt = cache?.lastResetCreditsAttemptAt else { return true }
        return Date().timeIntervalSince(lastAttemptAt) >= Self.resetCreditsRefreshInterval
    }

    private func shouldRefreshSubscription(_ cache: DailyUsageCache?) -> Bool {
        guard let lastAttemptAt = cache?.lastSubscriptionAttemptAt else { return true }
        return Date().timeIntervalSince(lastAttemptAt) >= Self.subscriptionRefreshInterval
    }

    private static func markRefreshAttempts(
        _ cache: DailyUsageCache?,
        resetCredits: Bool,
        subscription: Bool) -> DailyUsageCache
    {
        var cache = cache ?? DailyUsageCache(
            resetCredits: nil,
            subscriptionExpiresAt: nil,
            lastResetCreditsAttemptAt: nil,
            lastSubscriptionAttemptAt: nil)
        let now = Date()
        if resetCredits {
            cache.lastResetCreditsAttemptAt = now
        }
        if subscription {
            cache.lastSubscriptionAttemptAt = now
        }
        return cache
    }

    private func refreshAdditionalData(
        cached: DailyUsageCache,
        refreshResetCredits: Bool,
        refreshSubscription: Bool,
        client: CodexUsageClient,
        credentials: CodexCredentials,
        homePath: String) async throws -> DailyUsageCache
    {
        var cache = cached

        if refreshResetCredits {
            do {
                cache.resetCredits = CachedResetCredits(
                    try await client.fetchResetCredits(credentials: credentials, homePath: homePath))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the last successful value when the endpoint is unavailable.
            }
        }

        if refreshSubscription {
            do {
                cache.subscriptionExpiresAt = try await client.fetchSubscriptionExpiry(
                    credentials: credentials,
                    homePath: homePath)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the last successful value when the endpoint is unavailable.
            }
        }
        return cache
    }

    private static func merge(usage: CodexUsage, dailyData: DailyUsageCache) -> CodexUsage {
        CodexUsage(
            planType: usage.planType,
            primary: usage.primary,
            secondary: usage.secondary,
            credits: usage.credits,
            resetCredits: dailyData.resetCredits?.summary,
            fetchedAt: usage.fetchedAt,
            subscriptionExpiresAt: dailyData.subscriptionExpiresAt)
    }

    private static func loadDailyUsageCache() -> [String: DailyUsageCache] {
        guard let data = UserDefaults.standard.data(forKey: Self.dailyDataCacheKey),
              let cache = try? JSONDecoder().decode([String: DailyUsageCache].self, from: data)
        else { return [:] }
        return cache
    }

    private func saveDailyUsageCache() {
        guard let data = try? JSONEncoder().encode(self.dailyUsageCacheByAccount) else { return }
        UserDefaults.standard.set(data, forKey: Self.dailyDataCacheKey)
    }

    @objc private func addAccount() {
        self.beginLogin(replacing: nil)
    }

    @objc private func reloginAccount(_ sender: NSMenuItem) {
        guard self.reloadAccounts(), let id = sender.representedObject as? String,
              let account = self.accounts.first(where: { $0.id == id }) else { return }
        self.beginLogin(replacing: account)
    }

    private func beginLogin(replacing account: CodexAccount?) {
        guard self.accountOperationTask == nil, self.reloadAccounts() else { return }
        self.cancelRefresh()
        self.loginInProgress = true
        self.accountOperationTask = Task { @MainActor in
            defer { self.finishAccountOperation() }
            do {
                if let account { await self.authCoordinator.cancel(for: account) }
                try Task.checkCancellation()
                let homeURL = try self.accountStore.createTemporaryHome()
                defer { self.accountStore.discardTemporaryHome(homeURL) }
                let originalData = account.flatMap { try? self.accountStore.authData(for: $0) }
                let systemURL = self.accountStore.systemHomeURL.appendingPathComponent("auth.json")
                let originalSystemData = try? Data(contentsOf: systemURL)
                try await CodexCLI().login(at: homeURL)
                try Task.checkCancellation()
                let data = try Data(contentsOf: homeURL.appendingPathComponent("auth.json"))
                let loggedInCredentials = try CodexAccountStore.parseCredentials(data: data)
                if loggedInCredentials.expiresAt.map({ $0 <= Date() }) == true {
                    throw CodexUsageError.unauthorized
                }
                let registered: CodexAccount
                if let account {
                    registered = try self.accountStore.replaceCredentials(for: account, with: data, expectedData: originalData)
                    self.clearCache(for: account)
                } else {
                    let currentData = try? Data(contentsOf: systemURL)
                    let currentCredentials = currentData.flatMap { try? CodexAccountStore.parseCredentials(data: $0) }
                    if let identity = loggedInCredentials.identity, let currentIdentity = currentCredentials?.identity,
                       identity.matches(currentIdentity), currentData != originalSystemData
                    {
                        throw CodexUsageError.credentialsChanged
                    }
                    registered = try self.accountStore.importLogin(at: homeURL)
                }
                self.clearCache(for: registered)
                _ = self.reloadAccounts()
                self.selectedAccountID = self.accounts.first(where: { $0.cacheKey == registered.cacheKey })?.id
                    ?? self.accounts.first?.id
                UserDefaults.standard.set(self.selectedAccountID, forKey: "selectedAccountID")
            } catch is CancellationError {
            } catch {
                self.showAlert(title: self.text.loginFailed, message: self.text.errorMessage(error))
            }
        }
        self.rebuildMenu()
    }

    @objc private func cancelLogin() {
        guard self.loginInProgress else { return }
        self.accountOperationTask?.cancel()
    }

    @objc private func deleteAccount(_ sender: NSMenuItem) {
        guard self.accountOperationTask == nil, self.reloadAccounts(),
              let id = sender.representedObject as? String,
              let account = self.accounts.first(where: { $0.id == id }) else { return }
        guard !self.accountStore.isCurrentAccount(account) else {
            self.showAlert(title: self.text.unableToManageAccount, message: self.text.errorMessage(CodexUsageError.currentAccountRemoval))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = self.text.deleteAccountTitle(account)
        alert.informativeText = self.text.deleteAccountMessage
        alert.addButton(withTitle: self.text.deleteAccount)
        alert.addButton(withTitle: self.text.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        self.cancelRefresh()
        self.accountOperationTask = Task { @MainActor in
            defer { self.finishAccountOperation() }
            await self.authCoordinator.cancel(for: account)
            do {
                try Task.checkCancellation()
                try self.accountStore.removeAccount(account)
                self.clearCache(for: account)
                _ = self.reloadAccounts()
            } catch is CancellationError {
            } catch {
                _ = self.reloadAccounts()
                self.showAlert(title: self.text.unableToManageAccount, message: self.text.errorMessage(error))
            }
        }
        self.rebuildMenu()
    }

    private func clearCache(for account: CodexAccount) {
        self.usageByAccount[account.cacheKey] = nil
        self.errorByAccount[account.cacheKey] = nil
        self.dailyUsageCacheByAccount[account.cacheKey] = nil
        self.observedCredentials[account.cacheKey] = nil
        self.needsRefresh.insert(account.cacheKey)
        self.saveDailyUsageCache()
    }

    private func finishAccountOperation() {
        self.accountOperationTask = nil
        self.loginInProgress = false
        guard !self.isTerminating else { return }
        self.rebuildMenu()
        self.refreshSelectedAccount()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CodexUsage",
            .applicationVersion: Self.appReleaseVersion,
            .credits: NSAttributedString(string: self.text.aboutDescription),
        ])
    }

    @objc private func checkForUpdates() {
        self.updateCheckTask?.cancel()
        self.updateCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let update = try await self.updateChecker.check(currentVersion: Self.appReleaseVersion)
                guard !Task.isCancelled else { return }
                self.showUpdateResult(update)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.showAlert(title: self.text.updateCheckFailed, message: self.text.updateErrorMessage(error))
            }
        }
    }

    private func showUpdateResult(_ update: CodexUpdateInfo) {
        let alert = NSAlert()
        if update.isUpdateAvailable {
            alert.messageText = self.text.updateAvailable
            alert.informativeText = self.text.updateAvailableMessage(update.latestVersion)
            alert.addButton(withTitle: self.text.openRelease)
            alert.addButton(withTitle: self.text.ok)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.releaseURL)
            }
        } else {
            self.showAlert(
                title: self.text.upToDate,
                message: self.text.upToDateMessage(Self.appReleaseVersion))
        }
    }

    private func updateStatusIcon() {
        guard let account = self.selectedAccount else {
            self.statusItem.button?.image = CodexStatusIcon.image(primaryRemaining: nil, weeklyRemaining: nil)
            return
        }
        guard let usage = self.usageByAccount[account.cacheKey] else {
            self.statusItem.button?.image = CodexStatusIcon.image(primaryRemaining: nil, weeklyRemaining: nil)
            return
        }
        self.statusItem.button?.image = CodexStatusIcon.image(
            primaryRemaining: usage.primary?.remainingPercent,
            weeklyRemaining: usage.secondary?.remainingPercent)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: self.text.ok)
        alert.runModal()
    }

    private func codexError(_ error: Error) -> CodexUsageError {
        error as? CodexUsageError ?? .network(error.localizedDescription)
    }
}
