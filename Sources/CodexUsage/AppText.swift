import Foundation
import CodexUsageCore

enum CodexLanguage: String, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "language"

    static func load() -> Self {
        guard let rawValue = UserDefaults.standard.string(forKey: Self.defaultsKey),
              let language = Self(rawValue: rawValue)
        else {
            return .chinese
        }
        return language
    }
}

struct AppText {
    let language: CodexLanguage

    var statusAccessibilityTitle: String {
        self.value("Codex 额度", "Codex usage")
    }

    var languageTitle: String {
        self.value("语言", "Language")
    }

    var refresh: String {
        self.value("刷新", "Refresh")
    }

    var viewAccountUsage: String {
        self.value("查看账号额度", "View account usage")
    }

    var switchCodexAccount: String {
        self.value("切换 Codex 账号", "Switch Codex account")
    }

    var addAccount: String {
        self.value("添加账号…", "Add account…")
    }

    var manageAccounts: String { self.value("管理账号", "Manage accounts") }
    var relogin: String { self.value("重新登录…", "Log in again…") }
    var deleteAccount: String { self.value("删除账号…", "Delete account…") }
    var cancel: String { self.value("取消", "Cancel") }
    var cancelLogin: String { self.value("取消登录", "Cancel login") }
    var accountInUse: String { self.value("当前 Codex 使用中", "Currently used by Codex") }
    var unableToManageAccount: String { self.value("账号操作失败", "Account operation failed") }
    var loginInProgress: String { self.value("请在浏览器中完成登录，可在管理账号中取消。", "Complete login in your browser. You can cancel in Manage accounts.") }
    var deleteAccountMessage: String {
        self.value("将删除此应用保存的登录凭据和额度缓存。再次使用需要重新添加。",
                   "This removes the saved credentials and usage cache from this app. Add the account again to use it later.")
    }

    func deleteAccountTitle(_ account: CodexAccount) -> String {
        self.value("删除账号 \(self.accountName(account))？", "Delete account \(self.accountName(account))?")
    }

    var about: String {
        self.value("关于", "About")
    }

    var quit: String {
        self.value("退出", "Quit")
    }

    var checkForUpdates: String {
        self.value("检查更新…", "Check for Updates…")
    }

    var updateAvailable: String {
        self.value("发现新版本", "Update Available")
    }

    var upToDate: String {
        self.value("已是最新版本", "You're Up to Date")
    }

    var openRelease: String {
        self.value("打开下载页面", "Open Download Page")
    }

    var updateCheckFailed: String {
        self.value("检查更新失败", "Update Check Failed")
    }

    var currentAccount: String {
        self.value("当前 Codex 账号", "Current Codex account")
    }

    var noAccount: String {
        self.value("未找到 Codex 账号", "No Codex account found")
    }

    var loginHint: String {
        self.value("请先运行 codex login", "Run codex login first")
    }

    var refreshing: String {
        self.value("正在刷新…", "Refreshing…")
    }

    var noUsage: String {
        self.value("暂无额度数据", "No usage data")
    }

    var resetCreditsUnavailable: String {
        self.value("重置额度：暂不可用", "Reset credits: unavailable")
    }

    var plan: String {
        self.value("套餐", "Plan")
    }

    var subscriptionExpiryUnknown: String {
        self.value("订阅到期：未知", "Subscription expiry: unknown")
    }

    var updated: String {
        self.value("更新时间", "Updated")
    }

    var aboutDescription: String {
        self.value(
            "查看 Codex 额度、重置额度，以及查看或切换账号。",
            "View Codex usage, reset credits, and view or switch accounts.")
    }

    var ok: String {
        self.value("好", "OK")
    }

    var unableToSwitchAccount: String {
        self.value("无法切换账号", "Unable to switch account")
    }

    var unableToAddAccount: String {
        self.value("无法添加账号", "Unable to add account")
    }

    var addingAccount: String {
        self.value("正在添加账号", "Adding account")
    }

    var addingAccountMessage: String {
        self.value(
            "浏览器登录完成后，账号会自动出现在“切换 Codex 账号”菜单中。",
            "The account will appear in “Switch Codex account” after browser login completes.")
    }

    var loginFailed: String {
        self.value("账号登录失败", "Account login failed")
    }

    var retryLogin: String {
        self.value("请重试，或在终端运行 codex login。", "Retry, or run codex login in Terminal.")
    }

    func accountName(_ account: CodexAccount) -> String {
        if account.source == .system {
            if !account.email.isEmpty {
                return account.email
            }
            return self.currentAccount
        }
        if !account.email.isEmpty {
            return account.email
        }
        return URL(fileURLWithPath: account.homePath).lastPathComponent
    }

    func fiveHourQuota(_ window: CodexRateWindow?) -> String {
        let percent = window.map(\.remainingPercent).map(String.init) ?? "--"
        return self.value(
            "5 小时额度：剩余 \(percent)% · \(self.resetDescription(window?.resetAt))",
            "5-hour quota: \(percent)% remaining · \(self.resetDescription(window?.resetAt))")
    }

    func weeklyQuota(_ window: CodexRateWindow?) -> String {
        let percent = window.map(\.remainingPercent).map(String.init) ?? "--"
        return self.value(
            "周额度：剩余 \(percent)% · \(self.resetDescription(window?.resetAt))",
            "Weekly quota: \(percent)% remaining · \(self.resetDescription(window?.resetAt))")
    }

    func credits(_ value: Double) -> String {
        self.value("Credits：\(self.number(value))", "Credits: \(self.number(value))")
    }

    func resetCredits(_ summary: CodexResetCreditSummary) -> String {
        let expiry = summary.nextExpiry.map(self.expiryDescription) ?? self.value("无到期时间", "No expiry")
        return self.value(
            "重置额度：\(summary.availableCount) 个可用 · \(expiry)",
            "Reset credits: \(summary.availableCount) available · \(expiry)")
    }

    func subscriptionExpiry(_ date: Date?) -> String {
        guard let date else { return self.subscriptionExpiryUnknown }
        return self.value(
            "订阅到期：\(self.date(date)) · \(self.expiryDescription(date))",
            "Subscription expires: \(self.date(date)) · \(self.expiryDescription(date))")
    }

    func updated(_ date: Date) -> String {
        "\(self.updated)：\(self.time(date))"
    }

    func updateAvailableMessage(_ version: String) -> String {
        self.value(
            "发现新版本 \(version)，是否打开下载页面？",
            "Version \(version) is available. Open the download page?")
    }

    func upToDateMessage(_ version: String) -> String {
        self.value(
            "当前已是最新版本（\(version)）。",
            "You're already using the latest version (\(version)).")
    }

    func updateErrorMessage(_ error: Error) -> String {
        guard let error = error as? CodexUpdateError else {
            return error.localizedDescription
        }
        switch error {
        case .invalidResponse:
            return self.value("更新信息格式无法识别。", "Unable to understand the update information.")
        case .invalidVersion:
            return self.value("当前版本号无法识别。", "Unable to identify the current version.")
        case let .server(statusCode):
            return self.value(
                "更新服务返回错误（HTTP \(statusCode)）。",
                "The update service returned an error (HTTP \(statusCode)).")
        case let .network(message):
            return self.value("网络请求失败：\(message)", "Network request failed: \(message)")
        }
    }

    func errorMessage(_ error: Error) -> String {
        guard let error = error as? CodexUsageError else {
            return error.localizedDescription
        }

        switch error {
        case .authFileMissing:
            return self.value(
                "没有找到此账号的登录凭据，请在管理账号中重新登录。",
                "Credentials for this account are missing. Log in again in Manage accounts.")
        case .invalidAuth:
            return self.value(
                "此账号的登录凭据无法解析，请在管理账号中重新登录。",
                "Credentials for this account are invalid. Log in again in Manage accounts.")
        case .unauthorized:
            return self.value(
                "此账号需要重新登录，请在管理账号中选择重新登录。",
                "This account needs to log in again. Choose Log in again in Manage accounts.")
        case .forbidden:
            return self.value("额度接口拒绝访问（HTTP 403），请检查账号权限或网络访问限制。",
                              "Usage access was denied (HTTP 403). Check account permissions or network restrictions.")
        case .unsupportedAuth:
            return self.value("API Key 登录不支持查询 ChatGPT 订阅额度，请添加 ChatGPT 账号。",
                              "API key login cannot query ChatGPT subscription limits. Add a ChatGPT account.")
        case .credentialsChanged:
            return self.value("账号登录状态已在其他地方更新，请刷新后重试。",
                              "Account credentials changed elsewhere. Refresh and try again.")
        case .identityMismatch:
            return self.value("登录的账号或工作区与原账号不一致，原登录状态已保留。",
                              "The login belongs to another account or workspace. The original credentials were preserved.")
        case .currentAccountRemoval:
            return self.value("此账号正在被 Codex 使用，请先切换到其他账号再删除。",
                              "Codex is using this account. Switch to another account before deleting it.")
        case .accountStorage:
            return self.value("账号文件操作失败，请检查文件权限后重试。",
                              "Unable to update account files. Check file permissions and retry.")
        case .authenticationUnavailable:
            return self.value("自动续期失败，请检查网络和 Codex CLI 版本后重试，或重新登录此账号。",
                              "Automatic renewal failed. Check your network and Codex CLI version, or log in to this account again.")
        case .operationTimedOut:
            return self.value("账号操作超时，请重试。", "The account operation timed out. Please retry.")
        case .loginFailed:
            return self.value("账号登录未完成，原登录状态已保留。",
                              "Login did not complete. The original credentials were preserved.")
        case .invalidResponse:
            return self.value(
                "Codex 返回的数据格式无法识别。",
                "Unable to understand the Codex response.")
        case let .server(statusCode):
            return self.value(
                "Codex 服务返回错误（HTTP \(statusCode)）。",
                "Codex returned an error (HTTP \(statusCode)).")
        case let .network(message):
            return self.value("网络请求失败：\(message)", "Network request failed: \(message)")
        case .codexExecutableMissing:
            return self.value(
                "没有找到 codex 命令，请先安装 Codex CLI。",
                "The codex command was not found. Install Codex CLI first.")
        case let .accountSwitch(message):
            return self.value(
                "切换账号失败：\(message)",
                "Account switch failed: \(self.accountSwitchDetail(message))")
        }
    }

    func resetDescription(_ date: Date?) -> String {
        guard let date else { return self.value("重置时间未知", "Reset time unknown") }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return self.value("即将重置", "Resetting soon") }
        if seconds < 3_600 {
            let minutes = max(1, seconds / 60)
            return self.value("约 \(minutes) 分钟后重置", "Resets in about \(minutes) min")
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            return self.value("约 \(hours) 小时后重置", "Resets in about \(hours) hr")
        }
        let days = seconds / 86_400
        return self.value("约 \(days) 天后重置", "Resets in about \(days) d")
    }

    private func expiryDescription(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return self.value("已到期", "Expired") }
        if seconds < 3_600 {
            let minutes = max(1, seconds / 60)
            return self.value("约 \(minutes) 分钟后到期", "Expires in about \(minutes) min")
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            return self.value("约 \(hours) 小时后到期", "Expires in about \(hours) hr")
        }
        let days = seconds / 86_400
        return self.value("约 \(days) 天后到期", "Expires in about \(days) d")
    }

    private func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: self.language == .english ? "en_US" : "zh_CN")
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: self.language == .english ? "en_US" : "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: self.language == .english ? "en_US" : "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return formatter.string(from: date)
    }

    private func accountSwitchDetail(_ message: String) -> String {
        guard self.language == .english else { return message }
        switch message {
        case "目标账号的 auth.json 无法读取":
            return "Unable to read the target account's auth.json."
        case "当前账号备份失败":
            return "Unable to back up the current account."
        case "无法更新当前 Codex auth.json":
            return "Unable to update the current Codex auth.json."
        default:
            return message
        }
    }

    private func value(_ chinese: String, _ english: String) -> String {
        self.language == .english ? english : chinese
    }
}
