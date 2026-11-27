import CodexUsageCore
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct CodexUsageCommand {
    private static let help = """
        Usage: codex-usage <command>

          status [--json]         Show quota for the active file-based login
          accounts                List accounts and their IDs; * marks the active login
          import [codex-home]     Save a login from auth.json (default: active Codex home)
          switch <id>             Activate a saved account by its listed ID
        """

    @MainActor
    static func main() async {
        umask(0o077)
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let store = CodexAccountStore()
            switch arguments.first {
            case "status", "accounts", "import", "switch":
                let lock = try self.acquireStoreLock(store)
                defer { close(lock) }
                try await self.run(arguments, store: store)
            default:
                try await self.run(arguments, store: store)
            }
        } catch {
            FileHandle.standardError.write(Data("codex-usage: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func acquireStoreLock(_ store: CodexAccountStore) throws -> Int32 {
        let directory = store.applicationSupportURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("credentials.lock").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CommandError("Cannot open the credential store lock.")
        }
        while lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            close(descriptor)
            throw CommandError("Cannot lock the credential store.")
        }
        return descriptor
    }

    @MainActor
    private static func run(_ arguments: [String], store: CodexAccountStore) async throws {
        switch arguments.first {
        case nil, "help", "--help", "-h":
            print(self.help)
        case "status" where arguments.count == 1 || arguments == ["status", "--json"]:
            guard let account = store.loadAccounts().first(where: { $0.source == .system }) else {
                throw CommandError("No active file-based login. Run codex login with file credential storage.")
            }
            let (usage, _) = try await CodexAuthCoordinator(store: store).fetchUsage(for: account, client: CodexUsageClient())
            if arguments.count == 2 {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(Status(account: account.displayName, usage: usage)), as: UTF8.self))
            } else {
                print("Account: \(account.displayName)")
                self.printWindow("5-hour", usage.primary)
                self.printWindow("Weekly", usage.secondary)
            }
        case "accounts" where arguments.count == 1:
            for account in store.loadAccounts() {
                let marker = account.source == .system ? "*" : " "
                print("\(marker) \(account.id)\t\(account.displayName)")
            }
        case "import" where arguments.count <= 2:
            let home = arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let account = try store.importLogin(at: home ?? store.systemHomeURL)
            print("Saved \(account.displayName)")
        case "switch" where arguments.count == 2:
            guard let account = store.loadAccounts().first(where: { $0.id == arguments[1] }) else {
                throw CommandError("Unknown account ID. Run codex-usage accounts to list IDs.")
            }
            try store.activate(account)
            print("Active file-based login: \(account.displayName). Start a new Codex session with file credential storage.")
        default:
            throw CommandError(self.help)
        }
    }

    private static func printWindow(_ name: String, _ window: CodexRateWindow?) {
        guard let window else {
            print("\(name): unavailable")
            return
        }
        print("\(name): \(window.remainingPercent)% remaining (resets: \(self.date(window.resetAt)))")
    }

    private static func date(_ value: Date?) -> String {
        value.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
    }

    private struct CommandError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            self.errorDescription = message
        }
    }

    private struct Status: Encodable {
        struct Window: Encodable {
            let remainingPercent: Int
            let resetAt: Date?

            init(_ window: CodexRateWindow) {
                self.remainingPercent = window.remainingPercent
                self.resetAt = window.resetAt
            }
        }

        let account: String
        let primary: Window?
        let secondary: Window?

        init(account: String, usage: CodexUsage) {
            self.account = account
            self.primary = usage.primary.map(Window.init)
            self.secondary = usage.secondary.map(Window.init)
        }
    }
}
