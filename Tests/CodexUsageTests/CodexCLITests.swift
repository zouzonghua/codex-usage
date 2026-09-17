import Foundation
import Testing
import Darwin
@testable import CodexUsageCore

@Suite(.serialized)
@MainActor
struct CodexCLITests {
    @Test func refreshUsesTheManagedFileStoreAndJSONRPCHandshake() async throws {
        let fixture = try CLIFixture(script: #"""
        test "$1" = '-c' || exit 41
        test "$2" = 'cli_auth_credentials_store="file"' || exit 42
        test "$3" = 'app-server' || exit 43
        test "$4" = '--listen' || exit 44
        test "$5" = 'stdio://' || exit 45
        test -z "$OPENAI_API_KEY" || exit 46
        test -z "$CODEX_ACCESS_TOKEN" || exit 47
        IFS= read -r request
        case "$request" in *'"method":"initialize"'*) ;; *) exit 48 ;; esac
        printf '%s\n' '{"id":1,"result":{"userAgent":"test"}}'
        IFS= read -r request
        case "$request" in *'"method":"initialized"'*) ;; *) exit 49 ;; esac
        IFS= read -r request
        case "$request" in *'"method":"account/read"'*|*'"method":"account\/read"'*) ;; *) exit 50 ;; esac
        case "$request" in *'"refreshToken":true'*) ;; *) exit 51 ;; esac
        cp "$CODEX_HOME/renewed.json" "$CODEX_HOME/auth.json" || exit 52
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        while IFS= read -r request; do :; done
        """#)
        defer { fixture.cleanUp() }
        let renewed = Data("renewed-fixture".utf8)
        try renewed.write(to: fixture.home.appendingPathComponent("renewed.json"))

        try await CodexCLI(executable: fixture.executable, refreshTimeout: 3).refreshCredentials(at: fixture.home)

        #expect(try Data(contentsOf: fixture.home.appendingPathComponent("auth.json")) == renewed)
    }

    @Test(arguments: ["expired", "unsupported", "network"])
    func classifiesProtocolFailuresWithoutExposingResponses(mode: String) async throws {
        let message = mode == "expired" ? "refresh_token_expired"
            : (mode == "unsupported" ? "Method not found" : "connection refused")
        let fixture = try CLIFixture(script: """
        IFS= read -r request
        printf '%s\\n' '{"id":1,"error":{"code":-32601,"message":"\(message) secret-fixture"}}'
        while IFS= read -r request; do :; done
        """)
        defer { fixture.cleanUp() }
        let expected: CodexUsageError = mode == "expired" ? .unauthorized : .authenticationUnavailable
        await #expect(throws: expected) {
            try await CodexCLI(executable: fixture.executable, refreshTimeout: 3).refreshCredentials(at: fixture.home)
        }
        #expect(!expected.localizedDescription.contains("secret-fixture"))
    }

    @Test func refreshTimesOutAndReapsTheProcess() async throws {
        let fixture = try CLIFixture(script: #"""
        printf '%s' "$$" > "$CODEX_HOME/pid"
        while IFS= read -r request; do :; done
        """#)
        defer { fixture.cleanUp() }
        await #expect(throws: CodexUsageError.operationTimedOut) {
            try await CodexCLI(executable: fixture.executable, refreshTimeout: 3).refreshCredentials(at: fixture.home)
        }
        let pid = try #require(Int32(String(contentsOf: fixture.home.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func cancellingLoginWaitsForTheProcessToExit() async throws {
        let fixture = try CLIFixture(script: #"""
        test "$3" = 'login' || exit 41
        printf '%s' "$$" > "$CODEX_HOME/pid"
        while IFS= read -r request; do :; done
        """#)
        defer { fixture.cleanUp() }
        let request = Task { try await CodexCLI(executable: fixture.executable, loginTimeout: 10).login(at: fixture.home) }
        let pidFile = fixture.home.appendingPathComponent("pid")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: [0, 1])
    func reportsLoginExitStatus(status: Int) async throws {
        let fixture = try CLIFixture(script: "exit \(status)")
        defer { fixture.cleanUp() }
        let cli = CodexCLI(executable: fixture.executable, loginTimeout: 3)
        if status == 0 {
            try await cli.login(at: fixture.home)
        } else {
            await #expect(throws: CodexUsageError.loginFailed) { try await cli.login(at: fixture.home) }
        }
    }

    @Test func missingCLIHasAnActionableError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: CodexUsageError.codexExecutableMissing) {
            try await CodexCLI(executable: root.appendingPathComponent("missing-cli")).refreshCredentials(at: root)
        }
    }
}

private struct CLIFixture {
    let home: URL
    let executable: URL

    init(script: String) throws {
        self.home = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCLITests-\(UUID().uuidString)")
        self.executable = self.home.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + script + "\n").write(to: self.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.executable.path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: self.home) }
}
