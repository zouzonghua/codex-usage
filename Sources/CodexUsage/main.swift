import AppKit
import CodexUsageCore

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let appVersion = "0.1.0"
    private static let automaticRefreshInterval: TimeInterval = 300
    private static let menuRefreshInterval: TimeInterval = 60
    private let accountStore = CodexAccountStore()
    private let usageClient = CodexUsageClient()
    private var statusItem: NSStatusItem!
    private var language = CodexLanguage.load()
    private var accounts: [CodexAccount] = []
    private var selectedAccountID: String?
    private var usageByAccount: [String: CodexUsage] = [:]
    private var errorByAccount: [String: CodexUsageError] = [:]
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestID: UUID?
    private var refreshingAccountID: String?
    private var loginProcesses: [String: Process] = [:]
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

        self.accounts = self.accountStore.loadAccounts()
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
        self.refreshTimer?.invalidate()
        self.clockTimer?.invalidate()
        self.refreshTask?.cancel()
    }

    func menuWillOpen(_ menu: NSMenu) {
        _ = menu
        self.rebuildMenu()
        self.refreshSelectedAccount(ifOlderThan: Self.menuRefreshInterval)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if let account = self.selectedAccount {
            if !account.email.isEmpty {
                menu.addItem(self.infoItem(title: account.email))
                menu.addItem(.separator())
            }
            if let usage = self.usageByAccount[account.id] {
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
                menu.addItem(.separator())
                menu.addItem(self.infoItem(title: self.text.updated(usage.fetchedAt)))
            } else if let error = self.errorByAccount[account.id] {
                menu.addItem(self.infoItem(title: self.text.errorMessage(error)))
            } else if self.refreshingAccountID == account.id {
                menu.addItem(self.infoItem(title: self.text.refreshing))
            } else {
                menu.addItem(self.infoItem(title: self.text.noUsage))
            }
        } else {
            menu.addItem(self.infoItem(title: self.text.noAccount))
            menu.addItem(self.infoItem(title: self.text.loginHint))
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: self.text.refresh, action: #selector(refreshMenuAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(self.viewAccountUsageMenuItem())
        menu.addItem(self.switchCodexAccountMenuItem())
        menu.addItem(.separator())
        menu.addItem(self.languageMenuItem())
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: self.text.about, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

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
        for account in self.accounts where account.source == .saved {
            let item = NSMenuItem(
                title: self.text.accountName(account),
                action: #selector(switchCodexAccount(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            submenu.addItem(item)
        }
        if self.accounts.contains(where: { $0.source == .saved }) {
            submenu.addItem(.separator())
        }
        let addItem = NSMenuItem(title: self.text.addAccount, action: #selector(addAccount), keyEquivalent: "")
        addItem.target = self
        submenu.addItem(addItem)
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
              self.accounts.contains(where: { $0.id == id })
        else { return }

        self.cancelRefresh()
        self.selectedAccountID = id
        self.usageByAccount[id] = nil
        self.errorByAccount[id] = nil
        UserDefaults.standard.set(self.selectedAccountID, forKey: "selectedAccountID")
        self.rebuildMenu()
        self.refreshSelectedAccount()
    }

    @objc private func switchCodexAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let account = self.accounts.first(where: { $0.id == id && $0.source == .saved })
        else { return }

        do {
            try self.accountStore.activate(account)
            self.accounts = self.accountStore.loadAccounts()
        } catch {
            self.showAlert(
                title: self.text.unableToSwitchAccount,
                message: self.text.errorMessage(error))
            return
        }

        self.cancelRefresh()
        self.selectedAccountID = self.accounts.first(where: { $0.source == .system })?.id
        if let selectedAccountID = self.selectedAccountID {
            self.usageByAccount[selectedAccountID] = nil
            self.errorByAccount[selectedAccountID] = nil
        }
        UserDefaults.standard.set(self.selectedAccountID, forKey: "selectedAccountID")
        self.rebuildMenu()
        self.refreshSelectedAccount()
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

    private func refreshSelectedAccount(ifOlderThan minimumAge: TimeInterval? = nil) {
        guard let account = self.selectedAccount else {
            self.rebuildMenu()
            return
        }
        if self.refreshingAccountID == account.id {
            return
        }
        if let minimumAge,
           let usage = self.usageByAccount[account.id],
           Date().timeIntervalSince(usage.fetchedAt) < minimumAge
        {
            return
        }
        self.cancelRefresh()
        do {
            let credentials = try self.accountStore.credentials(for: account)
            let requestID = UUID()
            self.refreshRequestID = requestID
            self.refreshingAccountID = account.id
            self.errorByAccount[account.id] = nil
            self.rebuildMenu()
            let accountID = account.id
            let client = self.usageClient
            let homePath = account.homePath
            self.refreshTask = Task {
                do {
                    let usage = try await client.fetch(credentials: credentials, homePath: homePath)
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.selectedAccountID == accountID,
                              self.refreshRequestID == requestID
                        else { return }
                        self.usageByAccount[accountID] = usage
                        self.errorByAccount[accountID] = nil
                        self.refreshingAccountID = nil
                        self.refreshTask = nil
                        self.refreshRequestID = nil
                        self.rebuildMenu()
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.selectedAccountID == accountID,
                              self.refreshRequestID == requestID
                        else { return }
                        self.refreshingAccountID = nil
                        self.refreshTask = nil
                        self.refreshRequestID = nil
                        self.rebuildMenu()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.selectedAccountID == accountID,
                              self.refreshRequestID == requestID
                        else { return }
                        self.errorByAccount[accountID] = self.codexError(error)
                        self.refreshingAccountID = nil
                        self.refreshTask = nil
                        self.refreshRequestID = nil
                        self.rebuildMenu()
                    }
                }
            }
        } catch {
            self.errorByAccount[account.id] = self.codexError(error)
            self.refreshingAccountID = nil
            self.refreshTask = nil
            self.refreshRequestID = nil
            self.rebuildMenu()
        }
    }

    private func cancelRefresh() {
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.refreshRequestID = nil
        self.refreshingAccountID = nil
    }

    @objc private func addAccount() {
        do {
            let homeURL = try self.accountStore.createManagedHome()
            guard let executable = Self.codexExecutable() else {
                self.accountStore.removeManagedHome(homeURL)
                self.showAlert(
                    title: self.text.unableToAddAccount,
                    message: self.text.errorMessage(CodexUsageError.codexExecutableMissing))
                return
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["login"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = homeURL.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let homePath = homeURL.path
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    self?.finishLogin(homePath: homePath, status: process.terminationStatus)
                }
            }
            self.loginProcesses[homePath] = process
            try process.run()
            self.showAlert(
                title: self.text.addingAccount,
                message: self.text.addingAccountMessage)
        } catch {
            self.showAlert(
                title: self.text.unableToAddAccount,
                message: self.text.errorMessage(error))
        }
    }

    private func finishLogin(homePath: String, status: Int32) {
        self.loginProcesses.removeValue(forKey: homePath)
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
        guard status == 0 else {
            self.accountStore.removeManagedHome(homeURL)
            self.showAlert(title: self.text.loginFailed, message: self.text.retryLogin)
            return
        }
        do {
            let account = try self.accountStore.registerManagedAccount(at: homeURL)
            self.accounts = self.accountStore.loadAccounts()
            self.selectedAccountID = account.id
            UserDefaults.standard.set(account.id, forKey: "selectedAccountID")
            self.rebuildMenu()
            self.refreshSelectedAccount()
        } catch {
            self.accountStore.removeManagedHome(homeURL)
            self.showAlert(
                title: self.text.loginFailed,
                message: self.text.errorMessage(error))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CodexUsage",
            .applicationVersion: Self.appVersion,
            .credits: NSAttributedString(string: self.text.aboutDescription),
        ])
    }

    private func updateStatusIcon() {
        guard let account = self.selectedAccount else {
            self.statusItem.button?.image = CodexStatusIcon.image(primaryRemaining: nil, weeklyRemaining: nil)
            return
        }
        guard let usage = self.usageByAccount[account.id] else {
            self.statusItem.button?.image = CodexStatusIcon.image(primaryRemaining: nil, weeklyRemaining: nil)
            return
        }
        self.statusItem.button?.image = CodexStatusIcon.image(
            primaryRemaining: usage.primary?.remainingPercent,
            weeklyRemaining: usage.secondary?.remainingPercent)
    }

    private static func codexExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["PATH"]?.split(separator: ":")
            .map({ "\($0)/codex" })
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
        {
            return URL(fileURLWithPath: path)
        }
        return nil
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
