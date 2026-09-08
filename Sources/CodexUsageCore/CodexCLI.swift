import Foundation
import Darwin

public struct CodexCLI: Sendable {
    private let executable: URL?
    private let refreshTimeout: TimeInterval
    private let loginTimeout: TimeInterval

    public init(executable: URL? = nil, refreshTimeout: TimeInterval = 30, loginTimeout: TimeInterval = 300) {
        self.executable = executable
        self.refreshTimeout = refreshTimeout
        self.loginTimeout = loginTimeout
    }

    @MainActor public func refreshCredentials(at homeURL: URL) async throws {
        try await self.run(at: homeURL, refreshing: true, timeout: self.refreshTimeout)
    }

    @MainActor public func login(at homeURL: URL) async throws {
        try await self.run(at: homeURL, refreshing: false, timeout: self.loginTimeout)
    }

    @MainActor private func run(at homeURL: URL, refreshing: Bool, timeout: TimeInterval) async throws {
        guard let executable = self.executable ?? Self.executableURL(),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexUsageError.codexExecutableMissing
        }
        let operation = CodexCLIOperation(executable: executable, homeURL: homeURL, refreshing: refreshing)
        try await operation.run(timeout: timeout)
    }

    public static func executableURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/codex" }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                  home.appendingPathComponent(".local/bin/codex").path,
                  home.appendingPathComponent(".npm-global/bin/codex").path]
        let nodeVersions = (try? fileManager.contentsOfDirectory(
            at: home.appendingPathComponent(".nvm/versions/node"), includingPropertiesForKeys: nil)) ?? []
        paths += nodeVersions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/codex").path }
        return paths.first(where: { fileManager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

@MainActor
private final class CodexCLIOperation {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let refreshing: Bool
    private var buffer = Data()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var requestedRefresh = false

    init(executable: URL, homeURL: URL, refreshing: Bool) {
        self.refreshing = refreshing
        self.process.executableURL = executable
        self.process.currentDirectoryURL = homeURL
        self.process.arguments = ["-c", "cli_auth_credentials_store=\"file\""]
            + (refreshing ? ["app-server", "--listen", "stdio://"] : ["login"])
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.path
        environment["CODEX_ACCESS_TOKEN"] = nil
        environment["OPENAI_API_KEY"] = nil
        environment["PATH"] = executable.deletingLastPathComponent().path + ":"
            + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        self.process.environment = environment
        self.process.standardInput = self.input
        self.process.standardOutput = self.output
        self.process.standardError = self.errors
    }

    func run(timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    Task { @MainActor in self?.receive(data) }
                }
                self.errors.fileHandleForReading.readabilityHandler = { handle in
                    _ = handle.availableData
                }
                self.process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { @MainActor in self?.terminated(status: status) }
                }
                do {
                    try self.process.run()
                    if self.refreshing {
                        try self.send(["id": 1, "method": "initialize", "params": [
                            "clientInfo": ["name": "codex_usage", "version": "1.0.0"],
                        ]])
                    }
                    self.timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.stop(with: .failure(CodexUsageError.operationTimedOut))
                    }
                } catch {
                    self.stop(with: .failure(CodexUsageError.authenticationUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop(with: .failure(CancellationError())) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try self.input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard self.refreshing, self.result == nil, !data.isEmpty else { return }
        self.buffer.append(data)
        guard self.buffer.count <= 1_048_576 else {
            self.stop(with: .failure(CodexUsageError.authenticationUnavailable))
            return
        }
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            let line = self.buffer.prefix(upTo: newline)
            self.buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                self.stop(with: .failure(CodexUsageError.authenticationUnavailable))
                return
            }
            guard let id = message["id"] as? Int, id == 1 || id == 2 else { continue }
            if let error = message["error"] as? [String: Any] {
                let detail = (error["message"] as? String ?? "").lowercased()
                let requiresLogin = ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
                                     "refresh token has expired", "refresh token has already been used",
                                     "refresh token has been revoked", "not authenticated", "unauthorized"]
                    .contains { detail.contains($0) }
                self.stop(with: .failure(requiresLogin ? CodexUsageError.unauthorized : .authenticationUnavailable))
                return
            }
            guard let response = message["result"] as? [String: Any] else {
                self.stop(with: .failure(CodexUsageError.authenticationUnavailable))
                return
            }
            if id == 1, !self.requestedRefresh {
                self.requestedRefresh = true
                do {
                    try self.send(["method": "initialized", "params": [:]])
                    try self.send(["id": 2, "method": "account/read", "params": ["refreshToken": true]])
                } catch {
                    self.stop(with: .failure(CodexUsageError.authenticationUnavailable))
                }
            } else if id == 2, self.requestedRefresh {
                guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                    self.stop(with: .failure(CodexUsageError.unauthorized))
                    return
                }
                self.stop(with: .success(()))
                return
            }
        }
    }

    private func stop(with result: Result<Void, Error>) {
        guard self.continuation != nil, self.result == nil else { return }
        self.result = result
        if self.process.isRunning {
            self.process.terminate()
            self.terminationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        } else {
            self.complete()
        }
    }

    private func terminated(status: Int32) {
        if self.result == nil {
            self.result = !self.refreshing && status == 0 ? .success(())
                : .failure(self.refreshing ? CodexUsageError.authenticationUnavailable : .loginFailed)
        }
        self.complete()
    }

    private func complete() {
        self.timeoutTask?.cancel()
        self.terminationTask?.cancel()
        self.output.fileHandleForReading.readabilityHandler = nil
        self.errors.fileHandleForReading.readabilityHandler = nil
        try? self.input.fileHandleForWriting.close()
        try? self.output.fileHandleForReading.close()
        try? self.errors.fileHandleForReading.close()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: self.result ?? .failure(CodexUsageError.authenticationUnavailable))
    }
}
