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

    var about: String {
        self.value("关于", "About")
    }

    var quit: String {
        self.value("退出", "Quit")
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

    func errorMessage(_ error: Error) -> String {
        guard let error = error as? CodexUsageError else {
            return error.localizedDescription
        }

        switch error {
        case .authFileMissing:
            return self.value(
                "没有找到 auth.json，请先运行 codex login。",
                "auth.json not found. Run codex login first.")
        case .invalidAuth:
            return self.value(
                "auth.json 无法解析，请重新运行 codex login。",
                "Unable to parse auth.json. Run codex login again.")
        case .unauthorized:
            return self.value(
                "Codex 登录状态已失效，请重新运行 codex login。",
                "Codex login has expired. Run codex login again.")
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
